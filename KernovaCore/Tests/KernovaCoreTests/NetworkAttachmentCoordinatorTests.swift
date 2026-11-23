import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("NetworkAttachmentCoordinator Tests", .caseScoped)
@MainActor
struct NetworkAttachmentCoordinatorTests {
    private static let wiFi = BridgedInterface(identifier: "en0", localizedDisplayName: "Wi-Fi")
    private static let ethernet = BridgedInterface(
        identifier: "en1", localizedDisplayName: "Ethernet")

    /// Mutable choice the coordinator's `choice` closure reads, standing in for
    /// the live `VMConfiguration`.
    @MainActor
    private final class ChoiceBox {
        var choice: NetworkChoice?
        init(_ choice: NetworkChoice?) { self.choice = choice }
    }

    /// Mutable eligibility the coordinator's `isEligible` closure reads,
    /// standing in for the live `VMInstance.status` gate.
    @MainActor
    private final class EligibilityBox {
        var isEligible = true
    }

    private struct Harness {
        let coordinator: NetworkAttachmentCoordinator
        let device: MockNetworkDeviceControl
        let provider: MockBridgedInterfaceProvider
        let vmnet: ScriptedVmnetNetworks
        /// The VM the coordinator's session view is for.
        let owner: UUID
        let observer: MockNetworkLinkObserver
        let clock: TestEngineClock
        let eligibility: EligibilityBox
        let choiceBox: ChoiceBox
        let reports: ReportRecorder
        /// How many networks the harness stood up before the coordinator ran.
        let preMaterialized: Int

        /// The kind of every network created since the harness stood its own
        /// up, failed creates included, in call order.
        var materializeRequests: [VmnetNetworkKind] {
            Array(vmnet.operations.createdKinds.dropFirst(preMaterialized))
        }

        /// The subnet the `kind` network in `scope` hands out, `nil` while it
        /// is not materialized.
        func subnet(_ kind: VmnetNetworkKind, _ scope: VmnetNetworkID.Scope) -> IPv4Subnet? {
            vmnet.service.ipv4Subnet(for: VmnetNetworkID(kind: kind, scope: scope))
        }
    }

    /// Records every attachment report, standing in for
    /// `VMInstance.networkAttachment`.
    @MainActor
    private final class ReportRecorder {
        private(set) var values: [NetworkAttachmentState?] = []
        func record(_ value: NetworkAttachmentState?) { values.append(value) }
    }

    private func makeHarness(
        choice: NetworkChoice?,
        devicePlan: NetworkAttachmentPlan? = nil,
        available: [BridgedInterface] = [],
        primary: String? = nil,
        entitled: Bool = false,
        retryDelays: [TimeInterval] = [],
        materialized: [VmnetNetworkSelection] = [.common(.nat), .common(.hostOnly)]
    ) -> Harness {
        let provider = MockBridgedInterfaceProvider(available: available, primary: primary)
        let vmnet = ScriptedVmnetNetworks()
        let owner = UUID()
        let sessionNetworks = vmnet.service.sessionNetworks(ownedBy: owner)
        let device = MockNetworkDeviceControl(plan: devicePlan, vmnetNetworks: sessionNetworks)
        // In order: joining a network takes the VM off the one before it.
        for network in materialized { vmnet.join(network, through: sessionNetworks) }
        let observer = MockNetworkLinkObserver()
        let clock = TestEngineClock()
        let eligibility = EligibilityBox()
        let choiceBox = ChoiceBox(choice)
        let reports = ReportRecorder()
        let coordinator = NetworkAttachmentCoordinator(
            vmName: "Test VM",
            device: device,
            interfaces: provider,
            linkObserver: observer,
            vmnetNetworks: sessionNetworks,
            entitlements: entitled ? .entitled : .unentitled,
            retryDelays: retryDelays,
            clock: clock,
            isEligible: { eligibility.isEligible },
            choice: { choiceBox.choice },
            onAttachmentChange: { reports.record($0) })
        return Harness(
            coordinator: coordinator, device: device, provider: provider,
            vmnet: vmnet, owner: owner, observer: observer, clock: clock, eligibility: eligibility,
            choiceBox: choiceBox, reports: reports,
            preMaterialized: vmnet.operations.createdKinds.count)
    }

    // MARK: - Session start

    @Test("A materialization a later switch overtook leaves the VM on the network its device is on")
    func overtakenMaterializationLeavesTheDevicesNetwork() async throws {
        let lab = UUID()
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil, membership: .isolated),
            devicePlan: .vmnet(.own(.hostOnly)),
            entitled: true,
            materialized: [.own(.hostOnly)])
        h.coordinator.activate()
        #expect(h.device.appliedPlans.isEmpty)

        let createHold = DispatchSemaphore(value: 0)
        h.vmnet.operations.setCreateHold(createHold)
        h.choiceBox.choice = NetworkChoice(
            mode: .hostOnly, bridgedInterfaceIdentifier: nil, membership: .network(lab))
        h.coordinator.configurationChanged()
        #expect(h.coordinator.isPending)
        try await h.vmnet.operations.createEntered.wait { h.materializeRequests == [.hostOnly] }

        // The user switches back before the named network's create returns.
        h.choiceBox.choice = NetworkChoice(
            mode: .hostOnly, bridgedInterfaceIdentifier: nil, membership: .isolated)
        h.coordinator.configurationChanged()
        #expect(h.device.currentPlan == .vmnet(.own(.hostOnly)))
        #expect(!h.coordinator.isPending)

        createHold.signal()
        try await h.coordinator.vmnetMaterializationTaskForTesting?.joined()

        #expect(h.subnet(.hostOnly, .vm(h.owner)) != nil)
        #expect(h.subnet(.hostOnly, .named(lab)) == nil)
        #expect(h.vmnet.operations.releasedNetworks.count == 1)
        #expect(h.device.currentPlan == .vmnet(.own(.hostOnly)))
        #expect(!h.coordinator.isPending)
        h.coordinator.stop()
    }

    // MARK: - Disconnect

    @Test("A Bridged VM whose interface is gone joins its own NAT network, never the default-route interface")
    func goneInterfaceJoinsOwnNATNotPrimary() async throws {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en1"),
            devicePlan: .bridged("en1"),
            available: [Self.ethernet],
            primary: "en1",
            entitled: true)
        h.coordinator.activate()

        // en1 undocked: the host now offers only Wi-Fi, which carries the
        // default route.
        h.provider.setAvailable([Self.wiFi])
        h.provider.setPrimary("en0")
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("undock"))
        try await h.coordinator.vmnetMaterializationTaskForTesting?.joined()

        #expect(!h.device.appliedPlans.contains(.bridged("en0")))
        #expect(h.device.currentPlan == .vmnet(.own(.nat)))
        #expect(h.subnet(.nat, .vm(h.owner)) != nil)
        #expect(!h.coordinator.isPending)
        h.coordinator.stop()
    }
}
