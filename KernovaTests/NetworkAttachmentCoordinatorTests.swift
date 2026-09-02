import Foundation
import KernovaTestSupport
import Testing
@testable import Kernova

@Suite("NetworkAttachmentCoordinator Tests", .admissionGated)
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
        let vmnet: MockVmnetNetworkProvider
        let observer: MockNetworkLinkObserver
        let clock: TestEngineClock
        let eligibility: EligibilityBox
        let choiceBox: ChoiceBox
        let pendingChanges: PendingRecorder
        let defectReports: DefectReportRecorder
    }

    /// Records every pending-state callback, standing in for
    /// `VMInstance.networkAttachmentPending`.
    @MainActor
    private final class PendingRecorder {
        private(set) var values: [Bool] = []
        func record(_ value: Bool) { values.append(value) }
    }

    /// Counts the suspected-defective-network reports, standing in for the
    /// library arbitration pass `VMInstance.onNetworkArbitrationNeeded` runs.
    @MainActor
    private final class DefectReportRecorder {
        private(set) var count = 0
        /// Run at each report, so a test can drive the arbiter's answer from
        /// inside the report the way the real wiring does.
        var onReport: (@MainActor () -> Void)?
        func record() {
            count += 1
            onReport?()
        }
    }

    private func makeHarness(
        choice: NetworkChoice?,
        devicePlan: NetworkAttachmentPlan? = nil,
        available: [BridgedInterface] = [],
        primary: String? = nil,
        entitled: Bool = false,
        retryDelays: [TimeInterval] = []
    ) -> Harness {
        let device = MockNetworkDeviceControl(plan: devicePlan)
        let provider = MockBridgedInterfaceProvider(available: available, primary: primary)
        let vmnet = MockVmnetNetworkProvider()
        let observer = MockNetworkLinkObserver()
        let clock = TestEngineClock()
        let eligibility = EligibilityBox()
        let choiceBox = ChoiceBox(choice)
        let pendingChanges = PendingRecorder()
        let defectReports = DefectReportRecorder()
        let coordinator = NetworkAttachmentCoordinator(
            vmName: "Test VM",
            device: device,
            interfaces: provider,
            linkObserver: observer,
            vmnetNetworks: vmnet,
            isVMNetworkingEntitled: entitled,
            retryDelays: retryDelays,
            clock: clock,
            isEligible: { eligibility.isEligible },
            choice: { choiceBox.choice },
            onPendingChange: { pendingChanges.record($0) },
            onNetworkDefectSuspected: { defectReports.record() })
        return Harness(
            coordinator: coordinator, device: device, provider: provider,
            vmnet: vmnet, observer: observer, clock: clock, eligibility: eligibility,
            choiceBox: choiceBox, pendingChanges: pendingChanges,
            defectReports: defectReports)
    }

    // MARK: - Session start

    @Test("Activation reattaches a shared VM that came up detached")
    func activationReattachesDetachedSharedDevice() {
        let h = makeHarness(choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil))

        h.coordinator.activate()

        #expect(h.device.appliedPlans == [.nat])
        #expect(!h.coordinator.isPending)
        #expect(h.observer.isObserving)
    }

    @Test("Activation leaves a matching attachment alone")
    func activationLeavesMatchingAttachmentAlone() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0"),
            devicePlan: .bridged("en0"),
            available: [Self.wiFi])

        h.coordinator.activate()

        #expect(h.device.appliedPlans.isEmpty)
        #expect(!h.coordinator.isPending)
    }

    @Test("Activation attaches the app-managed Host Only network")
    func activationAttachesHostOnlyNetwork() {
        let h = makeHarness(choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil))

        h.coordinator.activate()

        #expect(h.device.appliedPlans == [.hostOnly])
        #expect(!h.coordinator.isPending)
    }

    @Test("An entitled build realizes Shared over the app-managed vmnet network")
    func entitledSharedRealizesVmnetPlan() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            entitled: true)

        h.coordinator.activate()

        #expect(h.device.appliedPlans == [.sharedVmnet])
        #expect(!h.coordinator.isPending)
    }

    @Test("An entitled build swaps a NAT attachment over to the vmnet shared network")
    func entitledSharedReplacesNATAttachment() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat,
            entitled: true)

        h.coordinator.activate()

        #expect(h.device.appliedPlans == [.sharedVmnet])
    }

    @Test("A Shared ladder burning out reports the shared network suspect, dropping nothing")
    func sharedLadderExhaustionReportsTheSharedNetwork() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            entitled: true,
            retryDelays: [])
        h.device.refusedPlans = [.sharedVmnet]
        h.vmnet.materializeFails = true

        h.coordinator.activate()

        // Every Shared VM shares the one network, so dropping it is the
        // library arbiter's call, never this session's.
        #expect(h.vmnet.invalidatedKinds.isEmpty)
        #expect(h.defectReports.count == 1)
        #expect(h.coordinator.suspectedDefectiveVmnetKind == .shared)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value
        h.coordinator.stop()
    }

    @Test("A live switch between vmnet-backed modes supersedes the in-flight materialization")
    func liveSwitchSupersedesInFlightMaterialization() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            entitled: true,
            retryDelays: [])
        h.vmnet.materializedKinds = []
        h.vmnet.materializeFails = true
        h.device.refusedPlans = [.hostOnly, .sharedVmnet]

        h.coordinator.activate()
        #expect(h.coordinator.isPending)

        // The Host Only drive is still in flight; switching to Shared must
        // replace it with one for the shared network, not be swallowed by the
        // single-flight guard — the old task's ladder would otherwise strand
        // the VM detached with no wake-up signal for the new kind. The
        // refusals lift only after the switch, so the supersede path (not a
        // direct attach) is what recovers the session.
        h.vmnet.materializeFails = false
        h.choiceBox.choice = NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil)
        h.coordinator.configurationChanged()
        h.device.refusedPlans = []

        await h.coordinator.vmnetMaterializationTaskForTesting?.value
        #expect(h.vmnet.materializeRequestedKinds.contains(.shared))
        #expect(h.device.appliedPlans.last == .sharedVmnet)
        #expect(!h.coordinator.isPending)
        h.coordinator.stop()
    }

    @Test("A Host Only network that won't materialize goes pending and retries on the ladder")
    func refusedHostOnlyAttachRetriesOnBackoff() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            retryDelays: [1])
        h.device.refusedPlans = [.hostOnly]

        h.coordinator.activate()
        #expect(h.coordinator.isPending)
        #expect(h.device.appliedPlans.isEmpty)

        h.device.refusedPlans = []
        guard let retry = h.coordinator.retryTaskForTesting else {
            Issue.record("Expected a scheduled retry")
            return
        }
        await retry.value

        #expect(h.device.appliedPlans == [.hostOnly])
        #expect(!h.coordinator.isPending)
    }

    @Test("An unmaterialized Host Only network materializes in the background and reconciles")
    func unmaterializedHostOnlyMaterializesAndReconciles() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            retryDelays: [])
        h.vmnet.materializedKinds = []
        h.device.refusedPlans = [.hostOnly]

        h.coordinator.activate()
        #expect(h.coordinator.isPending)

        // The network comes up between the refused apply and the
        // materialization task running; its completion is the reconcile
        // trigger — no ladder rung remains to deliver one.
        h.device.refusedPlans = []
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        #expect(h.device.appliedPlans == [.hostOnly])
        #expect(!h.coordinator.isPending)
        #expect(h.vmnet.materializeCount == 1)
    }

    @Test("Ladder exhaustion reports the network suspect once per pending episode")
    func ladderExhaustionReportsTheNetworkOnce() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            retryDelays: [])
        h.device.refusedPlans = [.hostOnly]
        h.vmnet.materializeFails = true

        h.coordinator.activate()
        #expect(h.defectReports.count == 1)
        #expect(h.coordinator.suspectedDefectiveVmnetKind == .hostOnly)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        // A later trigger while still pending exhausts the ladder again but
        // must not report a second time — one report per episode is what
        // bounds the recreate churn.
        h.observer.fire()
        #expect(h.defectReports.count == 1)
        #expect(h.vmnet.invalidatedKinds.isEmpty)
        h.coordinator.stop()
    }

    @Test("Attaching withdraws the suspicion, and the next episode can report again")
    func attachingWithdrawsTheSuspicion() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            retryDelays: [])
        h.device.refusedPlans = [.hostOnly]
        h.vmnet.materializeFails = true

        h.coordinator.activate()
        #expect(h.coordinator.suspectedDefectiveVmnetKind == .hostOnly)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        // The session recovers on its own before any arbiter acted: the claim
        // is withdrawn rather than queued, so nothing recreates the network.
        h.device.refusedPlans = []
        h.vmnet.materializeFails = false
        h.observer.fire()
        #expect(!h.coordinator.isPending)
        #expect(h.coordinator.suspectedDefectiveVmnetKind == nil)

        // A fresh pending episode is free to report again.
        h.device.refusedPlans = [.hostOnly]
        h.vmnet.materializeFails = true
        h.device.attachmentWasDisconnected()
        h.observer.fire()
        #expect(h.coordinator.suspectedDefectiveVmnetKind == .hostOnly)
        #expect(h.defectReports.count == 2)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value
        h.coordinator.stop()
    }

    @Test("The arbiter's recreate withdraws the suspicion and reattaches the session")
    func recreateNudgeReattachesTheSession() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            retryDelays: [])
        h.device.refusedPlans = [.hostOnly]
        h.vmnet.materializeFails = true

        h.coordinator.activate()
        #expect(h.coordinator.suspectedDefectiveVmnetKind == .hostOnly)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        // The arbiter dropped the network and the recreate comes up healthy.
        // The retry ladder is spent, so this nudge is the only wake-up left.
        h.vmnet.materializedKinds = []
        h.vmnet.materializeFails = false
        h.device.refusedPlans = []
        h.coordinator.vmnetNetworkWasInvalidated(.hostOnly)
        #expect(h.coordinator.suspectedDefectiveVmnetKind == nil)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        #expect(h.device.appliedPlans == [.hostOnly])
        #expect(!h.coordinator.isPending)
    }

    @Test("A recreate of the other kind leaves this session's suspicion standing")
    func recreateNudgeForAnotherKindIsIgnored() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            retryDelays: [])
        h.device.refusedPlans = [.hostOnly]
        h.vmnet.materializeFails = true

        h.coordinator.activate()
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        let materializedBefore = h.vmnet.materializeRequestedKinds.count
        h.coordinator.vmnetNetworkWasInvalidated(.shared)

        #expect(h.coordinator.suspectedDefectiveVmnetKind == .hostOnly)
        #expect(h.vmnet.materializeRequestedKinds.count == materializedBefore)
        h.coordinator.stop()
    }

    @Test("A recreate that comes up just as defective is not reported again")
    func aStillDefectiveRecreateIsNotReportedTwice() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            retryDelays: [])
        h.device.refusedPlans = [.hostOnly]
        h.vmnet.materializeFails = true

        h.coordinator.activate()
        #expect(h.defectReports.count == 1)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        // The arbiter recreated the network; the claim is consumed by that.
        h.coordinator.vmnetNetworkWasInvalidated(.hostOnly)
        #expect(h.coordinator.suspectedDefectiveVmnetKind == nil)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        // The recreate is just as defective — the attachment still will not
        // hold — so the ladder burns out again. Reporting here would be a
        // recreate loop over a network nothing can fix.
        h.observer.fire()

        #expect(h.coordinator.isPending)
        #expect(h.defectReports.count == 1)
        #expect(h.coordinator.suspectedDefectiveVmnetKind == nil)
        h.coordinator.stop()
    }

    @Test("A live switch to a mode on no app-managed network withdraws the claim")
    func aSwitchOffTheSuspectNetworkWithdrawsTheClaim() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            retryDelays: [])
        h.device.refusedPlans = [.hostOnly]
        h.vmnet.materializeFails = true

        h.coordinator.activate()
        #expect(h.coordinator.suspectedDefectiveVmnetKind == .hostOnly)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        // Bridged with no usable interface resolves to nothing, so the session
        // never attaches and `setPending(false)` never runs — the claim has to
        // retire on the resolved network changing, or the arbiter would keep
        // recreating a network this VM left.
        h.choiceBox.choice = NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0")
        h.coordinator.configurationChanged()

        #expect(h.coordinator.isPending)
        #expect(h.coordinator.suspectedDefectiveVmnetKind == nil)
        #expect(h.defectReports.count == 1)
        h.coordinator.stop()
    }

    @Test("A live switch to the other vmnet mode restores the report budget")
    func aSwitchBetweenVmnetModesRestoresTheReportBudget() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            entitled: true,
            retryDelays: [])
        h.device.refusedPlans = [.hostOnly, .sharedVmnet]
        h.vmnet.materializeFails = true

        h.coordinator.activate()
        #expect(h.coordinator.suspectedDefectiveVmnetKind == .hostOnly)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        // One report per episode bounds churn on one network, not on every
        // network the session may move onto.
        h.choiceBox.choice = NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil)
        h.coordinator.configurationChanged()

        #expect(h.coordinator.suspectedDefectiveVmnetKind == .shared)
        #expect(h.defectReports.count == 2)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value
        h.coordinator.stop()
    }

    @Test("An ineligible session drops the arbiter's nudge")
    func recreateNudgeIsDroppedWhileIneligible() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            retryDelays: [])
        h.device.refusedPlans = [.hostOnly]
        h.vmnet.materializeFails = true

        h.coordinator.activate()
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        // A save-suspend: still active, but the reconcile a materialization
        // would trigger is dropped on eligibility, so the task would spin for
        // nothing. Activation at the next `.running` re-enters.
        h.eligibility.isEligible = false
        h.vmnet.materializeFails = false
        h.coordinator.vmnetNetworkWasInvalidated(.hostOnly)

        #expect(h.coordinator.vmnetMaterializationTaskForTesting == nil)
        #expect(h.coordinator.suspectedDefectiveVmnetKind == .hostOnly)
        h.coordinator.stop()
    }

    @Test("A stopped session withdraws its suspicion")
    func stopWithdrawsTheSuspicion() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil),
            retryDelays: [])
        h.device.refusedPlans = [.hostOnly]
        h.vmnet.materializeFails = true

        h.coordinator.activate()
        #expect(h.coordinator.suspectedDefectiveVmnetKind == .hostOnly)
        await h.coordinator.vmnetMaterializationTaskForTesting?.value

        h.coordinator.stop()

        #expect(h.coordinator.suspectedDefectiveVmnetKind == nil)
    }

    @Test("A bridged VM with no usable interface goes pending, then a link event reattaches it")
    func degradedBridgedStartRecoversOnLinkEvent() {
        let h = makeHarness(choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0"))

        h.coordinator.activate()
        #expect(h.coordinator.isPending)
        #expect(h.pendingChanges.values == [true])
        #expect(h.device.appliedPlans.isEmpty)

        h.provider.available = [Self.wiFi]
        h.observer.fire()

        #expect(h.device.appliedPlans == [.bridged("en0")])
        #expect(!h.coordinator.isPending)
        #expect(h.pendingChanges.values == [true, false])
    }

    // MARK: - Disconnect

    @Test("A shared-mode disconnect reattaches NAT immediately")
    func sharedDisconnectReattachesImmediately() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat)
        h.coordinator.activate()

        // The framework nils the attachment before the delegate callback.
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("link down"))

        #expect(h.device.appliedPlans == [.nat])
        #expect(!h.coordinator.isPending)
        #expect(h.pendingChanges.values.isEmpty)
    }

    @Test("A persistent attach-fail loop escalates the ladder and ends pending")
    func persistentAttachFailureEscalatesLadderThenRestsPending() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
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

    @Test("Disconnects outside the burst window each reattach immediately")
    func spacedDisconnectsReattachImmediately() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat)
        h.coordinator.activate()

        for round in 1...3 {
            h.device.plan = nil
            h.coordinator.attachmentWasDisconnected(error: TestFailure("link down"))
            #expect(h.device.appliedPlans.count == round)
            // The attachment holds long enough to outlive the burst window, so
            // the next disconnect is a fresh link event, not a failure report.
            h.clock.advance(seconds: NetworkAttachmentCoordinator.defaultDisconnectBurstWindow + 1)
        }

        #expect(h.device.appliedPlans == [.nat, .nat, .nat])
        #expect(!h.coordinator.isPending)
    }

    @Test("A bridged disconnect with the persisted interface gone narrows to the primary")
    func bridgedDisconnectNarrowsToPrimary() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en1"),
            devicePlan: .bridged("en1"),
            available: [Self.ethernet],
            primary: "en1")
        h.coordinator.activate()

        // en1 undocked: the host now offers only Wi-Fi.
        h.provider.available = [Self.wiFi]
        h.provider.primary = "en0"
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("undock"))

        #expect(h.device.appliedPlans == [.bridged("en0")])
        #expect(!h.coordinator.isPending)
    }

    @Test("The persisted interface returning reclaims the bridge from its narrowed fallback")
    func persistedInterfaceReturningReclaimsBridge() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en1"),
            devicePlan: .bridged("en0"),
            available: [Self.wiFi],
            primary: "en0")
        h.coordinator.activate()
        #expect(h.device.appliedPlans.isEmpty)

        h.provider.available = [Self.wiFi, Self.ethernet]
        h.observer.fire()

        #expect(h.device.appliedPlans == [.bridged("en1")])
    }

    @Test("An Automatic bridge holds its interface across a default-route change")
    func automaticBridgeHoldsInterfaceAcrossPrimaryChange() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: nil),
            devicePlan: .bridged("en0"),
            available: [Self.wiFi, Self.ethernet],
            primary: "en0")
        h.coordinator.activate()

        h.provider.primary = "en1"
        h.observer.fire()

        #expect(h.device.appliedPlans.isEmpty)
        #expect(h.device.currentPlan == .bridged("en0"))
    }

    @Test("A vanished interface detaches the stale bridge, goes pending, and arms a retry")
    func vanishedInterfaceDetachesStaleBridge() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en1"),
            devicePlan: .bridged("en1"),
            available: [Self.ethernet],
            primary: "en1",
            retryDelays: [60])
        h.coordinator.activate()
        #expect(!h.coordinator.isPending)

        // en1 pulled and the default route with it; the link event can land
        // before (or without) VZ's disconnect callback, so the live attachment
        // still names the vanished interface.
        h.provider.available = []
        h.provider.primary = nil
        h.observer.fire()

        #expect(h.device.detachCount == 1)
        #expect(h.device.currentPlan == nil)
        #expect(h.coordinator.isPending)
        #expect(h.coordinator.retryTaskForTesting != nil)
    }

    @Test("A narrowed fallback holds while the default route flaps away")
    func narrowedFallbackHeldWhilePrimaryGone() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en5"),
            devicePlan: .bridged("en0"),
            available: [Self.wiFi],
            primary: "en0")
        h.coordinator.activate()

        h.provider.primary = nil
        h.observer.fire()

        #expect(h.device.appliedPlans.isEmpty)
        #expect(h.device.detachCount == 0)
        #expect(h.device.currentPlan == .bridged("en0"))
        #expect(!h.coordinator.isPending)
    }

    @Test("An ineligible session drops triggers until re-activation")
    func ineligibleSessionDropsTriggers() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat)
        h.coordinator.activate()

        // Saving: the snapshot must not race an attachment mutation.
        h.eligibility.isEligible = false
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("mid-save"))
        h.observer.fire()
        h.coordinator.configurationChanged()
        #expect(h.device.appliedPlans.isEmpty)
        #expect(!h.coordinator.isPending)

        // Back to .running: activation re-reconciles the dropped state.
        h.eligibility.isEligible = true
        h.coordinator.activate()
        #expect(h.device.appliedPlans == [.nat])
    }

    // MARK: - Live configuration changes

    @Test("A live mode change swaps the attachment")
    func liveModeChangeSwapsAttachment() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat,
            available: [Self.wiFi],
            primary: "en0")
        h.coordinator.activate()

        h.choiceBox.choice = NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0")
        h.coordinator.configurationChanged()
        #expect(h.device.appliedPlans == [.bridged("en0")])

        h.choiceBox.choice = NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: "en0")
        h.coordinator.configurationChanged()
        #expect(h.device.appliedPlans == [.bridged("en0"), .nat])
        #expect(!h.coordinator.isPending)
    }

    @Test("A live switch to Host Only swaps the attachment, and back")
    func liveHostOnlySwitchSwapsAttachment() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat)
        h.coordinator.activate()

        h.choiceBox.choice = NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil)
        h.coordinator.configurationChanged()
        #expect(h.device.appliedPlans == [.hostOnly])
        #expect(!h.coordinator.isPending)

        h.choiceBox.choice = NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil)
        h.coordinator.configurationChanged()
        #expect(h.device.appliedPlans == [.hostOnly, .nat])
        #expect(!h.coordinator.isPending)
    }

    @Test("Switching to a Host Only network that won't materialize detaches rather than staying Shared")
    func refusedHostOnlySwitchDetaches() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat)
        h.coordinator.activate()
        h.device.refusedPlans = [.hostOnly]

        h.choiceBox.choice = NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil)
        h.coordinator.configurationChanged()

        // The NAT attachment must not survive as a silent substitute for the
        // chosen mode (docs/NETWORKING.md).
        #expect(h.device.detachCount == 1)
        #expect(h.device.currentPlan == nil)
        #expect(h.coordinator.isPending)
    }

    @Test("A live interface switch swaps the bridge")
    func liveInterfaceSwitchSwapsBridge() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0"),
            devicePlan: .bridged("en0"),
            available: [Self.wiFi, Self.ethernet])
        h.coordinator.activate()

        h.choiceBox.choice = NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en1")
        h.coordinator.configurationChanged()

        #expect(h.device.appliedPlans == [.bridged("en1")])
    }

    @Test("Switching to an unresolvable bridge detaches rather than keeping the old mode")
    func unresolvableBridgeSwitchDetaches() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat)
        h.coordinator.activate()

        h.choiceBox.choice = NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0")
        h.coordinator.configurationChanged()

        // The NAT attachment must not survive as a silent substitute for the
        // chosen mode (docs/NETWORKING.md).
        #expect(h.device.detachCount == 1)
        #expect(h.device.currentPlan == nil)
        #expect(h.coordinator.isPending)
    }

    // MARK: - Backoff retries

    @Test("A refused attach retries on the backoff schedule until it lands")
    func refusedAttachRetriesOnBackoff() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0"),
            available: [Self.wiFi],
            retryDelays: [1])
        // The interface is listed but the attach refuses — the VZ interface
        // list lagging the dynamic store.
        h.device.refusedPlans = [.bridged("en0")]

        h.coordinator.activate()
        #expect(h.coordinator.isPending)

        h.device.refusedPlans = []
        guard let retry = h.coordinator.retryTaskForTesting else {
            Issue.record("Expected a scheduled retry")
            return
        }
        await retry.value

        #expect(h.device.appliedPlans == [.bridged("en0")])
        #expect(!h.coordinator.isPending)
    }

    @Test("Exhausted retries leave recovery to the next link event")
    func exhaustedRetriesRecoverOnLinkEvent() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0"),
            available: [Self.wiFi])
        h.device.refusedPlans = [.bridged("en0")]

        h.coordinator.activate()
        #expect(h.coordinator.isPending)
        #expect(h.coordinator.retryTaskForTesting == nil)

        h.device.refusedPlans = []
        h.observer.fire()

        #expect(h.device.appliedPlans == [.bridged("en0")])
        #expect(!h.coordinator.isPending)
    }

    // MARK: - Lifecycle

    @Test("Events before activation are ignored")
    func eventsBeforeActivationAreIgnored() {
        let h = makeHarness(choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil))

        // The disconnect that fires benignly during boot/restore, before the
        // session reaches `.running`.
        h.coordinator.attachmentWasDisconnected(error: TestFailure("initial boot"))
        h.coordinator.configurationChanged()

        #expect(h.device.appliedPlans.isEmpty)
        #expect(!h.coordinator.isPending)
    }

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
