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
        let pendingChanges: PendingRecorder
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

    /// Records every pending-state callback, standing in for
    /// `VMInstance.networkAttachmentPending`.
    @MainActor
    private final class PendingRecorder {
        private(set) var values: [Bool] = []
        func record(_ value: Bool) { values.append(value) }
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
        let pendingChanges = PendingRecorder()
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
            onPendingChange: { pendingChanges.record($0) })
        return Harness(
            coordinator: coordinator, device: device, provider: provider,
            vmnet: vmnet, owner: owner, observer: observer, clock: clock, eligibility: eligibility,
            choiceBox: choiceBox, pendingChanges: pendingChanges,
            preMaterialized: vmnet.operations.createdKinds.count)
    }

    // MARK: - Session start

    @Test("A live switch between vmnet-backed modes supersedes the in-flight materialization")
    func liveSwitchSupersedesInFlightMaterialization() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            entitled: true,
            retryDelays: [],
            materialized: [])
        h.vmnet.operations.setCreateNetworkError(TestFailure("vmnet refused"))
        h.device.refusedPlans = [.vmnet(.common(.hostOnly)), .vmnet(.common(.nat))]

        h.coordinator.activate()
        #expect(h.coordinator.isPending)

        // The Host Only drive is still in flight; switching to NAT must
        // replace it with one for the NAT network, not be swallowed by the
        // single-flight guard — the old task's ladder would otherwise strand
        // the VM detached with no wake-up signal for the new kind. The
        // refusals lift only after the switch, so the supersede path (not a
        // direct attach) is what recovers the session.
        h.vmnet.operations.setCreateNetworkError(nil)
        h.choiceBox.choice = NetworkChoice(mode: .nat, bridgedInterfaceIdentifier: nil)
        h.coordinator.configurationChanged()
        h.device.refusedPlans = []

        await h.coordinator.vmnetMaterializationTaskForTesting?.value
        #expect(h.materializeRequests.contains(.nat))
        #expect(h.subnet(.nat, .common) != nil)
        #expect(h.device.appliedPlans.last == .vmnet(.common(.nat)))
        #expect(!h.coordinator.isPending)
        h.coordinator.stop()
    }

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
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        #expect(h.subnet(.hostOnly, .vm(h.owner)) != nil)
        #expect(h.subnet(.hostOnly, .named(lab)) == nil)
        #expect(h.vmnet.operations.releasedNetworks.count == 1)
        #expect(h.device.currentPlan == .vmnet(.own(.hostOnly)))
        #expect(!h.coordinator.isPending)
        h.coordinator.stop()
    }

    @Test("A bridged VM with no usable interface goes pending, then a link event reattaches it")
    func degradedBridgedStartRecoversOnLinkEvent() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0"),
            entitled: true)

        h.coordinator.activate()
        #expect(h.coordinator.isPending)
        #expect(h.pendingChanges.values == [true])
        #expect(h.device.appliedPlans.isEmpty)

        h.provider.setAvailable([Self.wiFi])
        h.observer.fire()

        #expect(h.device.appliedPlans == [.bridged("en0")])
        #expect(!h.coordinator.isPending)
        #expect(h.pendingChanges.values == [true, false])
    }

    // MARK: - Disconnect

    @Test("A persistent attach-fail loop escalates the ladder and ends pending")
    func persistentAttachFailureEscalatesLadderThenRestsPending() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .nat, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat,
            retryDelays: [1, 2])
        h.coordinator.activate()

        // VZ fails the attachment: the first disconnect reattaches immediately.
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("link down"))
        #expect(h.device.appliedPlans == [.nat])

        // Each reattach fails straight away — a live attach reports failure
        // only through another disconnect inside the burst window — so the
        // ladder paces every following attempt instead of reattaching in
        // lockstep, walking both rungs.
        for rung in 1...2 {
            h.device.plan = nil
            h.coordinator.attachmentWasDisconnected(error: TestFailure("attach failed"))
            #expect(h.device.appliedPlans.count == rung)
            #expect(h.coordinator.isPending)
            guard let retry = h.coordinator.retryTaskForTesting else {
                Issue.record("Expected a scheduled retry on rung \(rung)")
                return
            }
            await retry.value
            #expect(h.device.appliedPlans.count == rung + 1)
        }

        // Exhausted: the next failure report arms nothing and pending holds
        // until a link event or a disconnect outside the burst window.
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("attach failed"))
        #expect(h.coordinator.retryTaskForTesting == nil)
        #expect(h.device.appliedPlans.count == 3)
        #expect(h.coordinator.isPending)
    }

    @Test("A bridged disconnect with the persisted interface gone narrows to the primary")
    func bridgedDisconnectNarrowsToPrimary() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en1"),
            devicePlan: .bridged("en1"),
            available: [Self.ethernet],
            primary: "en1",
            entitled: true)
        h.coordinator.activate()

        // en1 undocked: the host now offers only Wi-Fi.
        h.provider.setAvailable([Self.wiFi])
        h.provider.setPrimary("en0")
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("undock"))

        #expect(h.device.appliedPlans == [.bridged("en0")])
        #expect(!h.coordinator.isPending)
    }

    @Test("A vanished interface detaches the stale bridge, goes pending, and arms a retry")
    func vanishedInterfaceDetachesStaleBridge() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en1"),
            devicePlan: .bridged("en1"),
            available: [Self.ethernet],
            primary: "en1",
            entitled: true,
            retryDelays: [60])
        h.coordinator.activate()
        #expect(!h.coordinator.isPending)

        // en1 pulled and the default route with it; the link event can land
        // before (or without) VZ's disconnect callback, so the live attachment
        // still names the vanished interface.
        h.provider.setAvailable([])
        h.provider.setPrimary(nil)
        h.observer.fire()

        #expect(h.device.detachCount == 1)
        #expect(h.device.currentPlan == nil)
        #expect(h.coordinator.isPending)
        #expect(h.coordinator.retryTaskForTesting != nil)
    }

    // MARK: - Backoff retries

    @Test("A ladder exhausted on a materialized vmnet network rests pending until the next link event")
    func exhaustedLadderOnMaterializedNetworkRestsPending() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .nat, bridgedInterfaceIdentifier: nil),
            entitled: true,
            retryDelays: [1])
        h.coordinator.activate()
        #expect(h.device.appliedPlans == [.vmnet(.common(.nat))])

        // Each attach onto the network fails straight away, reported through a
        // disconnect inside the burst window; the one rung paces the retry.
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("attach failed"))
        guard let retry = h.coordinator.retryTaskForTesting else {
            Issue.record("Expected a scheduled retry")
            return
        }
        await retry.value
        #expect(h.device.appliedPlans.count == 2)

        // Exhausted: nothing retries, and nothing rematerializes the network.
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("attach failed"))
        #expect(h.coordinator.retryTaskForTesting == nil)
        #expect(h.coordinator.vmnetMaterializationTaskForTesting == nil)
        #expect(h.materializeRequests.isEmpty)
        #expect(h.device.appliedPlans.count == 2)
        #expect(h.coordinator.isPending)

        h.observer.fire()

        #expect(h.device.appliedPlans.count == 3)
        #expect(!h.coordinator.isPending)
    }

    // MARK: - Lifecycle

    @Test("Stop cancels the retry and the link observation")
    func stopCancelsRetryAndObservation() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0"),
            retryDelays: [60])
        h.coordinator.activate()
        #expect(h.coordinator.isPending)
        #expect(h.coordinator.retryTaskForTesting != nil)

        h.coordinator.stop()

        #expect(h.coordinator.retryTaskForTesting == nil)
        #expect(!h.observer.isObserving)

        // Stopped means torn down: a late event must not touch the device.
        h.coordinator.attachmentWasDisconnected(error: TestFailure("late"))
        #expect(h.device.appliedPlans.isEmpty)
    }

    @Test("A missing network choice leaves the attachment alone")
    func missingChoiceLeavesAttachmentAlone() {
        let h = makeHarness(choice: nil, devicePlan: .nat)

        h.coordinator.activate()

        #expect(h.device.appliedPlans.isEmpty)
        #expect(h.device.detachCount == 0)
        #expect(!h.coordinator.isPending)
    }
}
