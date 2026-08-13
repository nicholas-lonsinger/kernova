import KernovaTestSupport
import Testing
@testable import Kernova

@Suite("NetworkAttachmentCoordinator Tests")
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

    private struct Harness {
        let coordinator: NetworkAttachmentCoordinator
        let device: MockNetworkDeviceControl
        let provider: MockBridgedInterfaceProvider
        let observer: MockNetworkLinkObserver
        let choiceBox: ChoiceBox
        let pendingChanges: PendingRecorder
    }

    /// Records every pending-state callback, standing in for
    /// `VMInstance.networkAttachmentPending`.
    @MainActor
    private final class PendingRecorder {
        private(set) var values: [Bool] = []
        func record(_ value: Bool) { values.append(value) }
        var latest: Bool { values.last ?? false }
    }

    private func makeHarness(
        choice: NetworkChoice?,
        devicePlan: NetworkAttachmentPlan? = nil,
        available: [BridgedInterface] = [],
        primary: String? = nil,
        retryDelays: [Duration] = [],
        disconnectBurstWindow: Duration = NetworkAttachmentCoordinator.defaultDisconnectBurstWindow
    ) -> Harness {
        let device = MockNetworkDeviceControl(plan: devicePlan)
        let provider = MockBridgedInterfaceProvider(available: available, primary: primary)
        let observer = MockNetworkLinkObserver()
        let choiceBox = ChoiceBox(choice)
        let pendingChanges = PendingRecorder()
        let coordinator = NetworkAttachmentCoordinator(
            vmName: "Test VM",
            device: device,
            interfaces: provider,
            linkObserver: observer,
            retryDelays: retryDelays,
            disconnectBurstWindow: disconnectBurstWindow,
            choice: { choiceBox.choice },
            onPendingChange: { pendingChanges.record($0) })
        return Harness(
            coordinator: coordinator, device: device, provider: provider,
            observer: observer, choiceBox: choiceBox, pendingChanges: pendingChanges)
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

    @Test("A disconnect burst paces reattach through the retry ladder")
    func disconnectBurstPacesReattachThroughRetryLadder() async {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat,
            retryDelays: [.milliseconds(1)])
        h.coordinator.activate()

        // VZ fails the attachment: the first disconnect reattaches immediately.
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("link down"))
        #expect(h.device.appliedPlans == [.nat])

        // VZ fails that reattach straight away — a live attach reports failure
        // only through another disconnect. Within the burst window the ladder
        // paces the next attempt instead of reattaching in lockstep.
        h.device.plan = nil
        h.coordinator.attachmentWasDisconnected(error: TestFailure("attach failed"))
        #expect(h.device.appliedPlans == [.nat])
        #expect(h.coordinator.isPending)

        guard let retry = h.coordinator.retryTaskForTesting else {
            Issue.record("Expected a scheduled retry")
            return
        }
        await retry.value
        #expect(h.device.appliedPlans == [.nat, .nat])
        #expect(!h.coordinator.isPending)
    }

    @Test("Disconnects outside the burst window each reattach immediately")
    func spacedDisconnectsReattachImmediately() {
        let h = makeHarness(
            choice: NetworkChoice(mode: .shared, bridgedInterfaceIdentifier: nil),
            devicePlan: .nat,
            disconnectBurstWindow: .zero)
        h.coordinator.activate()

        for _ in 1...3 {
            h.device.plan = nil
            h.coordinator.attachmentWasDisconnected(error: TestFailure("link down"))
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
            retryDelays: [.milliseconds(1)])
        // The interface is listed but the attach refuses — the VZ interface
        // list lagging the dynamic store.
        h.device.refusedBridgeIdentifiers = ["en0"]

        h.coordinator.activate()
        #expect(h.coordinator.isPending)

        h.device.refusedBridgeIdentifiers = []
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
        h.device.refusedBridgeIdentifiers = ["en0"]

        h.coordinator.activate()
        #expect(h.coordinator.isPending)
        #expect(h.coordinator.retryTaskForTesting == nil)

        h.device.refusedBridgeIdentifiers = []
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
            retryDelays: [.seconds(60)])
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
