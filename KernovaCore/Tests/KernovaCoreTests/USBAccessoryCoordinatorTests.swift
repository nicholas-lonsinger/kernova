import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What the coordinator does with an assignment: reconcile the guests' records,
/// then route it — back to the VM it is paired with, to a prompt, or nowhere.
@Suite("USB Accessory Coordinator Tests", .caseScoped)
@MainActor
struct USBAccessoryCoordinatorTests {
    /// The coordinator under test, wired as the app wires it: over a library
    /// that is its roster, its holders and its pairing funnel.
    private struct Harness {
        let lifecycle: VMLifecycleCoordinator
        let library: VMLibrary
        let coordinator: USBAccessoryCoordinator
    }

    /// Nothing else holds the coordinator — the closures it installs on the
    /// service capture it weakly, as the one real owner is
    /// `VMLibraryViewModel` — so a test that discards it is testing a
    /// coordinator that answers nothing, and every "leaves it alone" assertion
    /// passes for the wrong reason. Callers keep the returned harness alive
    /// for the length of the test; the library's VMs reach it weakly too.
    private func makeHarness(_ service: MockUSBAccessoryService) throws -> Harness {
        let lifecycle = makeTestLifecycle(usbAccessoryService: service)
        let library = makeWiredLibrary(lifecycle: lifecycle)
        let coordinator = try #require(
            USBAccessoryCoordinator(
                lifecycle: lifecycle, library: library))
        return Harness(lifecycle: lifecycle, library: library, coordinator: coordinator)
    }

    @discardableResult
    private func makeInstance(in h: Harness, sessionID: UUID, named name: String = "USB VM") -> VMInstance {
        let instance = makeStoppedInstance(in: h, named: name)
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContextForTesting()
        return instance
    }

    /// A VM with no session, for the tests that drive the edge onto one.
    @discardableResult
    private func makeStoppedInstance(in h: Harness, named name: String = "USB VM") -> VMInstance {
        h.library.registerFixture(name: name)
    }

    /// Records `accessory` against `instance`, the way an attach the user asked
    /// for would.
    @discardableResult
    private func pair(_ accessory: USBAccessoryInfo, with instance: VMInstance) throws
        -> USBAccessoryPairing
    {
        let pairing = try #require(USBAccessoryPairing.make(for: accessory))
        var pairings = instance.usbPairings
        pairings.upsert(pairing)
        instance.seedUSBPairings(pairings)
        return pairing
    }

    /// Whether every VM in the library is at rest with nothing queued on it.
    ///
    /// The coordinator's every attach is a follow-up, admitted or queued in
    /// the same turn as the assignment or edge that asks for it, so once this
    /// holds after that turn no attach is pending and none can start.
    private func nothingPending(in h: Harness) -> Bool {
        h.library.instances.allSatisfy {
            $0.phase.isSettled && $0.activity.queuedFollowUpCountForTesting == 0
        }
    }

    /// Collects the prompts a coordinator raises, leaving each unanswered.
    private final class PromptRecorder {
        var requests: [USBAccessoryPairingRequest] = []
    }

    /// Counts the take-backs an attachable edge runs.
    private final class TakeBackCounter {
        var count = 0
    }

    @Test("Starts the listener")
    func startsObserving() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        defer { withExtendedLifetime(h) {} }
        #expect(service.startObservingCallCount == 1)
    }

    @Test("Does not exist in a build that cannot pass accessories through")
    func absentWithoutTheCapability() {
        let lifecycle = makeTestLifecycle(usbAccessoryService: nil)
        let library = makeWiredLibrary(lifecycle: lifecycle)
        #expect(
            USBAccessoryCoordinator(
                lifecycle: lifecycle, library: library) == nil)
    }

    @Test("Drops a guest's record of an accessory the host has taken back")
    func aReassignmentClearsTheStaleRecord() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        defer { withExtendedLifetime(h) {} }
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "0373", receptacle: "hub/Port-A@1"))
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
        service.accessories.removeAll()
        #expect(instance.liveUSBAccessories.count == 1)

        // The same stick, back from the reset a detach causes: same serial,
        // same receptacle, new IORegistry node. The guest's record holds that
        // key, and this is the one arrival allowed to take it back.
        let echo = service.assignComposing(
            registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")

        #expect(echo.identity?.form == .serialNumber)
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    @Test("Leaves a guest's record alone for a second unit reporting the same serial")
    func aDuplicateSerialElsewhereLeavesTheRecordAlone() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        defer { withExtendedLifetime(h) {} }
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "0373", receptacle: "hub/Port-A@1"))
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
        service.accessories.removeAll()

        // A second stick of the same model, in another hole, whose vendor gave
        // it the serial the first one reports. Dropping the guest's record here
        // would leave it holding a device it could no longer detach.
        let second = service.assignComposing(
            registryID: 2, serial: "0373", receptacle: "hub/Port-A@2")

        #expect(second.identity?.form == .receptacle)
        #expect(instance.liveUSBAccessories.count == 1)
    }

    @Test("Leaves a guest's record alone when a different accessory arrives")
    func anUnrelatedAssignmentLeavesRecordsAlone() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        defer { withExtendedLifetime(h) {} }
        service.accessories.append(
            MockUSBAccessoryService.accessory(registryID: 1, serial: "0373"))
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)

        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "9999"))

        #expect(instance.liveUSBAccessories.count == 1)
    }

    @Test("Leaves records alone for an accessory nothing durable identifies")
    func anUnidentifiableAssignmentClearsNothing() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        defer { withExtendedLifetime(h) {} }
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 1))
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)

        // Both have a nil identity, and two nils are not a match.
        service.assign(MockUSBAccessoryService.accessory(registryID: 2))

        #expect(instance.liveUSBAccessories.count == 1)
    }

    // MARK: - Routing a Fresh Arrival

    @Test("An accessory paired with a running guest goes straight back to it")
    func aPairedAccessoryGoesBackToItsGuest() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeInstance(in: h, sessionID: UUID())
        defer { withExtendedLifetime(h) {} }
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-A@1")
        try pair(accessory, with: instance)

        service.assign(accessory)

        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [1])
    }

    @Test("An accessory paired with a virtual machine that is not running stays with the host")
    func aPairedAccessoryWaitsForItsGuest() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let stopped = makeStoppedInstance(in: h)
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        let accessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "0373")
        try pair(accessory, with: stopped)

        service.assign(accessory)

        // Held for the host, and not offered to anything else: the
        // user already said where this one goes.
        #expect(recorder.requests.isEmpty)
        #expect(nothingPending(in: h))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    @Test("An accessory no rule names is offered to the running guests")
    func anUnpairedAccessoryRaisesAPrompt() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let first = makeInstance(in: h, sessionID: UUID(), named: "First")
        let second = makeInstance(in: h, sessionID: UUID(), named: "Second")
        makeStoppedInstance(in: h, named: "Stopped")
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }

        service.assign(
            MockUSBAccessoryService.accessory(
                registryID: 7, serial: "0373", vendorName: "Samsung", productName: "Type-C"))

        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.accessory.registryID == 7)
        #expect(recorder.requests.first?.accessory.name == "Samsung Type-C")
        // Only the guests that could take it right now, and nothing attached
        // until the user answers.
        #expect(recorder.requests.first?.candidates.map(\.id) == [first.id, second.id])
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    @Test("An accessory no rule names is held when nothing is running")
    func anUnpairedAccessoryWithNoCandidatesIsHeld() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        makeStoppedInstance(in: h)
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }

        service.assign(MockUSBAccessoryService.accessory(registryID: 7, serial: "0373"))

        #expect(recorder.requests.isEmpty)
    }

    @Test("An accessory nothing durable identifies is never offered")
    func anUnidentifiableAccessoryRaisesNoPrompt() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        makeInstance(in: h, sessionID: UUID())
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }

        // Answering the prompt would create a rule keyed on nothing.
        service.assign(MockUSBAccessoryService.accessory(registryID: 7))

        #expect(recorder.requests.isEmpty)
    }

    @Test("At most one prompt is outstanding, however many accessories arrive")
    func promptsAreRaisedOneAtATime() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        makeInstance(in: h, sessionID: UUID())
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }

        // A fast user switch re-assigns every accessory at once, which would
        // otherwise raise one alert per device.
        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "B"))
        #expect(recorder.requests.count == 1)

        recorder.requests[0].answer(nil)

        #expect(recorder.requests.count == 2)
        #expect(recorder.requests[1].accessory.registryID == 2)
    }

    @Test("A queued prompt names the guests running when it is raised")
    func aQueuedPromptRederivesItsCandidates() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let first = makeInstance(in: h, sessionID: UUID(), named: "First")
        let second = makeStoppedInstance(in: h, named: "Second")
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "B"))
        #expect(recorder.requests.first?.candidates.map(\.id) == [first.id])

        // The library moves on while the second accessory waits its turn.
        first.handleSessionEvent(.guestDidStop)
        second.beginSessionContextForTesting()
        second.activity.placeForTesting(.running(sessionID: UUID()))
        recorder.requests[0].answer(nil)

        // Offering the guest that has since stopped would refuse the attach the
        // answer runs, and leave the one that is running unoffered.
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests[1].candidates.map(\.id) == [second.id])
    }

    @Test("A queued prompt is held when nothing is running by the time it is raised")
    func aQueuedPromptWithNoCandidatesIsHeld() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeInstance(in: h, sessionID: UUID())
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "B"))

        instance.handleSessionEvent(.guestDidStop)
        recorder.requests[0].answer(nil)

        #expect(recorder.requests.count == 1)
    }

    @Test("A queued prompt whose accessory has gone is dropped rather than raised")
    func aQueuedPromptForADepartedAccessoryIsDropped() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        makeInstance(in: h, sessionID: UUID())
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "B"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 3, serial: "C"))

        // Unplugged, or handed to another app, while it waited its turn.
        service.accessories.removeAll { $0.registryID == 2 }
        recorder.requests[0].answer(nil)

        // The one behind it is still there and is asked about instead.
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests[1].accessory.registryID == 3)
    }

    @Test("A queued prompt for an accessory a guest has taken is dropped")
    func aQueuedPromptForAHeldAccessoryIsDropped() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "B"))

        // Placed from the USB Device menu while its prompt waited its turn.
        try await h.lifecycle.attachUSBAccessory(2, to: instance, for: sessionID)
        recorder.requests[0].answer(nil)

        #expect(recorder.requests.count == 1)
    }

    @Test("Answering the same prompt twice raises nothing extra")
    func aSecondAnswerToOnePromptIsIgnored() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        makeInstance(in: h, sessionID: UUID())
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "B"))

        recorder.requests[0].answer(nil)
        recorder.requests[0].answer(nil)

        #expect(recorder.requests.count == 2)
    }

    // MARK: - The Guards

    @Test("An accessory two virtual machines claim is held rather than guessed at")
    func twoClaimantsHoldTheAccessory() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let first = makeInstance(in: h, sessionID: UUID(), named: "First")
        let second = makeInstance(in: h, sessionID: UUID(), named: "Second")
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        let accessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "0373")
        // Hand-edited files, or a bundle copied outside the app: which VM the
        // device belongs to is not decidable.
        try pair(accessory, with: first)
        try pair(accessory, with: second)

        service.assign(accessory)

        #expect(recorder.requests.isEmpty)
        #expect(nothingPending(in: h))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    @Test("A port-keyed rule holds while a second accessory of that model is around")
    func theWeakFormGuardHolds() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeInstance(in: h, sessionID: UUID())
        defer { withExtendedLifetime(h) {} }
        // No serial to key on, so the rule names the port rather than the unit.
        let paired = MockUSBAccessoryService.accessory(
            registryID: 1, receptacle: "hub/Port-A@1", productName: "Drive")
        try #require(paired.identity?.form == .receptacle)
        try pair(paired, with: instance)
        // A second unit of the same model, already assigned: whichever one is
        // now in the port, the key cannot say which.
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 2, receptacle: "hub/Port-A@2", productName: "Drive"))

        service.assign(paired)

        #expect(nothingPending(in: h))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    @Test("A port-keyed rule attaches while its model is the only one connected")
    func theWeakFormRuleStillWorksAlone() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeInstance(in: h, sessionID: UUID())
        defer { withExtendedLifetime(h) {} }
        let paired = MockUSBAccessoryService.accessory(
            registryID: 1, receptacle: "hub/Port-A@1", productName: "Drive")
        try pair(paired, with: instance)

        service.assign(paired)

        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [1])
    }

    // MARK: - Owed Returns

    /// Runs a warm capture's sweep on `instance`, and macOS withdraws each
    /// stick while the reset runs. Parks on `gate`, when given, before ending.
    private func capture(
        _ instance: VMInstance, service: MockUSBAccessoryService, gate: GatedStep? = nil
    ) async throws {
        try await instance.activity.captureSnapshot(.live) { context in
            try await VMLiveStateCapture.detachUSBAccessories(
                owingReturns: context, session: MockSnapshotSession(guestState: .running))
            service.accessories.removeAll()
            try await gate?.pass()
            return .rest(.asStarted, ())
        }
    }

    @Test("An accessory a capture took off goes back to that guest, whatever the pairings say")
    func anOwedReturnBypassesThePairings() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        let one = makeInstance(in: h, sessionID: UUID(), named: "One")
        let two = makeInstance(in: h, sessionID: UUID(), named: "Two")
        defer { withExtendedLifetime(h) {} }
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-A@1")
        // Two other VMs claim it, which on its own holds it for the host.
        try pair(accessory, with: one)
        try pair(accessory, with: two)
        service.accessories.append(accessory)
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)

        try await capture(instance, service: service)
        service.assignComposing(registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")

        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [1, 2])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [2])
    }

    @Test("An owed return is spent by one arrival, so the next one is routed as fresh")
    func anOwedReturnIsSpentOnce() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "0373", receptacle: "hub/Port-A@1"))
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
        try await capture(instance, service: service)
        let returned = service.assignComposing(
            registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }

        // Taken off again by something other than a capture: its next arrival
        // owes nothing, and nothing pairs it, so the user is asked.
        let attached = try #require(instance.liveUSBAccessories.first)
        try await h.lifecycle.detachUSBAccessory(
            deviceID: attached.deviceID, from: instance, for: sessionID)
        service.accessories.removeAll { $0.registryID == returned.registryID }
        service.assignComposing(registryID: 3, serial: "0373", receptacle: "hub/Port-A@1")

        #expect(recorder.requests.map(\.accessory.registryID) == [3])
        #expect(service.attachedRegistryIDs == [1, 2])
    }

    @Test("A detach the user asked for outranks an owed return, and both are spent")
    func aUserDetachOutranksAnOwedReturn() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        defer { withExtendedLifetime(h) {} }
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-A@1")
        let identity = try #require(accessory.identity)
        service.accessories.append(accessory)
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
        // What a detach the user asked for leaves armed when VZ refused it: the
        // accessory is still on the guest, and the user's last word is that it
        // belongs to the Mac.
        h.coordinator.userDetaching(accessory)

        try await capture(instance, service: service)
        service.assignComposing(registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")

        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        #expect(h.library.accessoryHolders.owedReturn(of: identity) == nil)
        #expect(instance.phase == .running(sessionID: sessionID))
        #expect(service.attachedRegistryIDs == [1])
    }

    @Test("A guest that goes away under the capture drops what it was owed")
    func aSessionEndDropsItsOwedReturns() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        defer { withExtendedLifetime(h) {} }
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-A@1")
        let identity = try #require(accessory.identity)
        service.accessories.append(accessory)
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
        let gate = GatedStep()
        let snapshot = Task { try? await capture(instance, service: service, gate: gate) }
        try await gate.waitUntilEntered()
        #expect(h.library.accessoryHolders.owedReturn(of: identity) === instance)

        instance.handleSessionEvent(.guestDidStop)
        #expect(h.library.accessoryHolders.owedReturn(of: identity) == nil)
        gate.release()
        _ = await snapshot.value
        service.assignComposing(registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")

        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        #expect(service.attachedRegistryIDs == [1])
        #expect(!instance.hasLiveVirtualMachine)
    }

    @Test("A return that arrives under the capture waits behind it, and a session end drops it")
    func aSessionEndDropsAQueuedReturn() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        defer { withExtendedLifetime(h) {} }
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "0373", receptacle: "hub/Port-A@1"))
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
        let gate = GatedStep()
        let snapshot = Task { try? await capture(instance, service: service, gate: gate) }
        try await gate.waitUntilEntered()
        service.assignComposing(registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)

        instance.handleSessionEvent(.guestDidStop)
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        gate.release()
        _ = await snapshot.value

        #expect(service.attachedRegistryIDs == [1])
        #expect(!instance.hasLiveVirtualMachine)
    }

    // MARK: - The User's Own Edits

    @Test("An attach the user asked for is remembered, and taken off every other VM")
    func aUserAttachRewritesTheRuleLibraryWide() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let first = makeInstance(in: h, sessionID: UUID(), named: "First")
        let second = makeInstance(in: h, sessionID: UUID(), named: "Second")
        defer { withExtendedLifetime(h) {} }
        let accessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "0373")
        try pair(accessory, with: first)

        try second.activity.edit(.pairingRules) { try h.coordinator.userAttached(accessory, $0) }

        // Moving a device between guests is a detach then an attach, and the
        // rewrite is what makes one key name one VM.
        #expect(first.usbPairings.isEmpty)
        #expect(second.usbPairings.pairings.map(\.key) == [accessory.identity?.key])
    }

    @Test("A detach the user asked for forgets the rule and the device stays with the Mac")
    func aUserDetachForgetsAndSuppressesTheEcho() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeInstance(in: h, sessionID: UUID())
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-A@1")
        try pair(accessory, with: instance)
        service.accessories.append(accessory)

        h.coordinator.userDetaching(accessory)
        try instance.activity.edit(.pairingRules) { try h.coordinator.userReleased(accessory, $0) }
        #expect(instance.usbPairings.isEmpty)

        // The detach resets the device, so macOS hands the same stick back
        // under a new registry ID. It must neither be re-attached nor prompted
        // for, or the user could never take it away.
        service.accessories.removeAll()
        service.assignComposing(registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")
        #expect(recorder.requests.isEmpty)
        #expect(nothingPending(in: h))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    @Test("The suppression is spent once, so a later replug is offered again")
    func theReleaseTokenIsSpentOnce() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        makeInstance(in: h, sessionID: UUID())
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-A@1")
        h.coordinator.userDetaching(accessory)

        service.assignComposing(registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")
        #expect(recorder.requests.isEmpty)

        // A token that outlived its own echo would silence the device for good.
        service.accessories.removeAll()
        service.assignComposing(registryID: 3, serial: "0373", receptacle: "hub/Port-A@1")
        #expect(recorder.requests.count == 1)
    }

    // MARK: - VM Start

    @Test("A guest that becomes attachable takes back every accessory paired with it, one attach after another")
    func aStartTakesBackItsAccessories() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeStoppedInstance(in: h)
        let other = makeStoppedInstance(in: h, named: "Other")
        defer { withExtendedLifetime(h) {} }
        instance.onSessionBecameAttachable = { [weak coordinator = h.coordinator] in
            coordinator?.sessionBecameAttachable(instance) ?? []
        }
        let mine = MockUSBAccessoryService.accessory(registryID: 1, serial: "A")
        let theirs = MockUSBAccessoryService.accessory(registryID: 2, serial: "B")
        let alsoMine = MockUSBAccessoryService.accessory(registryID: 3, serial: "C")
        try pair(mine, with: instance)
        try pair(theirs, with: other)
        try pair(alsoMine, with: instance)
        service.accessories = [mine, theirs, alsoMine]

        instance.beginSessionContextForTesting()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        // The first attach holds the VM; the second waits behind it.
        #expect(instance.phase.operation?.kind == .attachingUSB(registryID: 1))
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)
        try await waitForChange { instance.liveUSBAccessories.count == 2 }
        #expect(service.attachedRegistryIDs == [1, 3])
    }

    @Test("A start that ends running takes back its paired accessory in the step that settles it")
    func aRealStartAttachesInItsEndingStep() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeStoppedInstance(in: h)
        defer { withExtendedLifetime(h) {} }
        instance.onSessionBecameAttachable = { [weak coordinator = h.coordinator] in
            coordinator?.sessionBecameAttachable(instance) ?? []
        }
        let accessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "A")
        try pair(accessory, with: instance)
        service.accessories = [accessory]
        instance.beginSessionContextForTesting()
        let sessionID = UUID()
        service.suspendNextAttach = true

        try await instance.activity.launchStartGuest(.starting(recovery: false)) { context in
            context.bringUp.bindSessionForTesting(sessionID)
            return .rest(.live(.running), ())
        }.value()

        // The start's own ending admitted the attach: no other request could
        // be decided against the running VM in between.
        #expect(instance.phase.operation?.kind == .attachingUSB(registryID: 1))
        #expect(instance.phase.operation?.startedFrom == .running(sessionID: sessionID))
        try await service.attachStarted()
        service.resumeAttach()
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [1])
        #expect(instance.phase == .running(sessionID: sessionID))
    }

    @Test("Resuming a paused guest does not run the take-back again")
    func aResumeIsNotAnEdge() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeStoppedInstance(in: h)
        defer { withExtendedLifetime(h) {} }
        let takeBacks = TakeBackCounter()
        instance.onSessionBecameAttachable = { [weak coordinator = h.coordinator] in
            takeBacks.count += 1
            return coordinator?.sessionBecameAttachable(instance) ?? []
        }
        let accessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "A")
        try pair(accessory, with: instance)
        service.accessories = [accessory]
        let sessionID = UUID()
        instance.beginSessionContextForTesting()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        try await waitForChange { !instance.liveUSBAccessories.isEmpty && instance.phase.isSettled }

        // Both phases are attachable, so neither transition is an edge.
        instance.activity.placeForTesting(.livePaused(sessionID: sessionID))
        instance.activity.placeForTesting(.running(sessionID: sessionID))

        #expect(takeBacks.count == 1)
        #expect(nothingPending(in: h))
        #expect(service.attachedRegistryIDs == [1])
    }

    // MARK: - An Operation in Flight

    @Test("An accessory arriving during a snapshot delete attaches in the step the delete ends")
    func anArrivalDuringAnOperationAttachesAfterIt() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeInstance(in: h, sessionID: UUID())
        defer { withExtendedLifetime(h) {} }
        let accessory = MockUSBAccessoryService.accessory(registryID: 2, serial: "B")
        try pair(accessory, with: instance)
        let gate = GatedStep()
        let delete = try instance.activity.launch(.deletingSnapshot) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
        try await gate.waitUntilEntered()

        // The delete holds the VM, so the attach this assignment asks for
        // waits behind it rather than being refused.
        service.assign(accessory)
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)
        #expect(service.attachedRegistryIDs.isEmpty)

        service.suspendNextAttach = true
        gate.release()
        try await delete.value()
        // The delete's ending admitted it, so nothing else was decided between.
        #expect(instance.phase.operation?.kind == .attachingUSB(registryID: 2))
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        try await service.attachStarted()
        service.resumeAttach()
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [2])
    }

    @Test("Two accessories arriving under one operation both attach once it ends, in arrival order")
    func twoArrivalsUnderOneOperationBothAttach() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        defer { withExtendedLifetime(h) {} }
        let holding = MockUSBAccessoryService.accessory(registryID: 1, serial: "A")
        let first = MockUSBAccessoryService.accessory(registryID: 2, serial: "B")
        let second = MockUSBAccessoryService.accessory(registryID: 3, serial: "C")
        service.accessories.append(holding)
        try pair(first, with: instance)
        try pair(second, with: instance)

        service.suspendNextAttach = true
        let held = Task { try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID) }
        try await service.attachStarted()
        service.assign(first)
        service.assign(second)
        #expect(instance.activity.queuedFollowUpCountForTesting == 2)

        service.resumeAttach()
        _ = try await held.value
        try await waitForChange { instance.liveUSBAccessories.count == 3 }
        #expect(service.attachedRegistryIDs == [1, 2, 3])
    }

    @Test("A guest that goes away under an attach keeps the next accessory with the host")
    func aVMThatStopsUnderTheWaitHoldsTheAccessory() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        defer { withExtendedLifetime(h) {} }
        let first = MockUSBAccessoryService.accessory(registryID: 1, serial: "A")
        let second = MockUSBAccessoryService.accessory(registryID: 2, serial: "B")
        service.accessories.append(first)
        try pair(second, with: instance)

        service.suspendNextAttach = true
        let held = Task { try? await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID) }
        try await service.attachStarted()
        service.assign(second)
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)

        // The guest powers off while the attach still holds the VM, which
        // ends the attach the assignment queued for that session.
        instance.handleSessionEvent(.guestDidStop)
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        service.resumeAttach()
        _ = await held.value

        #expect(nothingPending(in: h))
        #expect(service.attachedRegistryIDs == [1])
        #expect(!instance.hasLiveVirtualMachine)
    }
}
