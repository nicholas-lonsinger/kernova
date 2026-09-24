import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// What the coordinator does with an assignment: reconcile the guests' records,
/// then route it — back to the VM it is paired with, to a prompt, or nowhere.
@Suite("USB Accessory Coordinator Tests", .admissionGated)
@MainActor
struct USBAccessoryCoordinatorTests {
    private func makeLifecycle(_ service: MockUSBAccessoryService) -> VMLifecycleCoordinator {
        makeTestLifecycle(usbAccessoryService: service)
    }

    /// The coordinator under test.
    ///
    /// Nothing else holds it — the closures it installs on the service capture
    /// it weakly, as the one real owner is `VMLibraryViewModel` — so a test
    /// that discards it is testing a coordinator that answers nothing, and
    /// every "leaves it alone" assertion passes for the wrong reason. Callers
    /// keep the returned value alive for the length of the test.
    private func makeCoordinator(
        _ lifecycle: VMLifecycleCoordinator, roster: StubVMInstanceRoster,
        pairings: StubUSBAccessoryPairingWriter? = nil
    ) throws -> USBAccessoryCoordinator {
        let writer = pairings ?? StubUSBAccessoryPairingWriter(roster: roster)
        writer.roster = roster
        return try #require(
            USBAccessoryCoordinator(lifecycle: lifecycle, roster: roster, pairings: writer))
    }

    private func makeInstance(sessionID: UUID, named name: String = "USB VM") -> VMInstance {
        let instance = makeStoppedInstance(named: name)
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        return instance
    }

    /// A VM with no session, for the tests that drive the edge onto one.
    private func makeStoppedInstance(named name: String = "USB VM") -> VMInstance {
        VMInstanceFixture.make(name: name)
    }

    /// Records `accessory` against `instance`, the way an attach the user asked
    /// for would.
    @discardableResult
    private func pair(_ accessory: USBAccessoryInfo, with instance: VMInstance) throws
        -> USBAccessoryPairing
    {
        let pairing = try #require(USBAccessoryPairing.make(for: accessory))
        instance.usbPairings.upsert(pairing)
        return pairing
    }

    /// Collects the prompts a coordinator raises, leaving each unanswered.
    private final class PromptRecorder {
        var requests: [USBAccessoryPairingRequest] = []
    }

    @Test("Starts the listener")
    func startsObserving() throws {
        let service = MockUSBAccessoryService()
        let coordinator = try makeCoordinator(makeLifecycle(service), roster: StubVMInstanceRoster())
        defer { withExtendedLifetime(coordinator) {} }
        #expect(service.startObservingCallCount == 1)
    }

    @Test("Does not exist in a build that cannot pass accessories through")
    func absentWithoutTheCapability() {
        let lifecycle = makeTestLifecycle(usbAccessoryService: nil)
        #expect(
            USBAccessoryCoordinator(
                lifecycle: lifecycle, roster: StubVMInstanceRoster(),
                pairings: StubUSBAccessoryPairingWriter()) == nil)
    }

    @Test("Drops a guest's record of an accessory the host has taken back")
    func aReassignmentClearsTheStaleRecord() async throws {
        let service = MockUSBAccessoryService()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        let lifecycle = makeLifecycle(service)
        let coordinator = try makeCoordinator(
            lifecycle, roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "0373", receptacle: "hub/Port-A@1"))
        try await lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
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
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        let lifecycle = makeLifecycle(service)
        let coordinator = try makeCoordinator(lifecycle, roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "0373", receptacle: "hub/Port-A@1"))
        try await lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
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
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        let lifecycle = makeLifecycle(service)
        let coordinator = try makeCoordinator(lifecycle, roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        service.accessories.append(
            MockUSBAccessoryService.accessory(registryID: 1, serial: "0373"))
        try await lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)

        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "9999"))

        #expect(instance.liveUSBAccessories.count == 1)
    }

    @Test("Leaves records alone for an accessory nothing durable identifies")
    func anUnidentifiableAssignmentClearsNothing() async throws {
        let service = MockUSBAccessoryService()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        let lifecycle = makeLifecycle(service)
        let coordinator = try makeCoordinator(lifecycle, roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 1))
        try await lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)

        // Both have a nil identity, and two nils are not a match.
        service.assign(MockUSBAccessoryService.accessory(registryID: 2))

        #expect(instance.liveUSBAccessories.count == 1)
    }

    // MARK: - Routing a Fresh Arrival

    @Test("An accessory paired with a running guest goes straight back to it")
    func aPairedAccessoryGoesBackToItsGuest() async throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-A@1")
        try pair(accessory, with: instance)

        service.assign(accessory)

        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [1])
    }

    @Test("An accessory paired with a virtual machine that is not running stays with the host")
    func aPairedAccessoryWaitsForItsGuest() async throws {
        let service = MockUSBAccessoryService()
        let stopped = makeStoppedInstance()
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([stopped]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }
        let accessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "0373")
        try pair(accessory, with: stopped)

        service.assign(accessory)

        // Held for the host, and not offered to anything else: the
        // user already said where this one goes.
        #expect(recorder.requests.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    @Test("An accessory no rule names is offered to the running guests")
    func anUnpairedAccessoryRaisesAPrompt() throws {
        let service = MockUSBAccessoryService()
        let first = makeInstance(sessionID: UUID(), named: "First")
        let second = makeInstance(sessionID: UUID(), named: "Second")
        let stopped = makeStoppedInstance(named: "Stopped")
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([first, second, stopped]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }

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
        let stopped = makeStoppedInstance()
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([stopped]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }

        service.assign(MockUSBAccessoryService.accessory(registryID: 7, serial: "0373"))

        #expect(recorder.requests.isEmpty)
    }

    @Test("An accessory nothing durable identifies is never offered")
    func anUnidentifiableAccessoryRaisesNoPrompt() throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }

        // Answering the prompt would create a rule keyed on nothing.
        service.assign(MockUSBAccessoryService.accessory(registryID: 7))

        #expect(recorder.requests.isEmpty)
    }

    @Test("At most one prompt is outstanding, however many accessories arrive")
    func promptsAreRaisedOneAtATime() throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }

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
        let first = makeInstance(sessionID: UUID(), named: "First")
        let second = makeStoppedInstance(named: "Second")
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([first, second]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "B"))
        #expect(recorder.requests.first?.candidates.map(\.id) == [first.id])

        // The library moves on while the second accessory waits its turn.
        first.tearDownSession(restingAt: .stopped)
        second.beginSessionContext()
        second.enter(.running(sessionID: UUID()))
        recorder.requests[0].answer(nil)

        // Offering the guest that has since stopped would refuse the attach the
        // answer runs, and leave the one that is running unoffered.
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests[1].candidates.map(\.id) == [second.id])
    }

    @Test("A queued prompt is held when nothing is running by the time it is raised")
    func aQueuedPromptWithNoCandidatesIsHeld() throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "B"))

        instance.tearDownSession(restingAt: .stopped)
        recorder.requests[0].answer(nil)

        #expect(recorder.requests.count == 1)
    }

    @Test("A queued prompt whose accessory has gone is dropped rather than raised")
    func aQueuedPromptForADepartedAccessoryIsDropped() throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }
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
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        let lifecycle = makeLifecycle(service)
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(lifecycle, roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "B"))

        // Placed from the USB Device menu while its prompt waited its turn.
        try await lifecycle.attachUSBAccessory(2, to: instance, for: sessionID)
        recorder.requests[0].answer(nil)

        #expect(recorder.requests.count == 1)
    }

    @Test("Answering the same prompt twice raises nothing extra")
    func aSecondAnswerToOnePromptIsIgnored() throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "B"))

        recorder.requests[0].answer(nil)
        recorder.requests[0].answer(nil)

        #expect(recorder.requests.count == 2)
    }

    // MARK: - The Guards

    @Test("An accessory two virtual machines claim is held rather than guessed at")
    func twoClaimantsHoldTheAccessory() async throws {
        let service = MockUSBAccessoryService()
        let first = makeInstance(sessionID: UUID(), named: "First")
        let second = makeInstance(sessionID: UUID(), named: "Second")
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([first, second]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }
        let accessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "0373")
        // Hand-edited files, or a bundle copied outside the app: which VM the
        // device belongs to is not decidable.
        try pair(accessory, with: first)
        try pair(accessory, with: second)

        service.assign(accessory)

        #expect(recorder.requests.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    @Test("A port-keyed rule holds while a second accessory of that model is around")
    func theWeakFormGuardHolds() async throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
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

        try await Task.sleep(for: .milliseconds(200))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    @Test("A port-keyed rule attaches while its model is the only one connected")
    func theWeakFormRuleStillWorksAlone() async throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        let paired = MockUSBAccessoryService.accessory(
            registryID: 1, receptacle: "hub/Port-A@1", productName: "Drive")
        try pair(paired, with: instance)

        service.assign(paired)

        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [1])
    }

    @Test("An accessory a capture is waiting for is reconciled and left alone")
    func anAwaitedReturnIsNotRouted() async throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-A@1")
        try pair(accessory, with: instance)
        let identity = try #require(accessory.identity)

        // A warm capture's put-back, already parked on this exact unit. The
        // pairing names the same VM, so without the arrival both would attach
        // it.
        let putBack = Task {
            await service.accessory(matching: identity, appearingWithin: .seconds(5))
        }
        try await service.waitStarted.wait { service.parkedWaitCount == 1 }
        service.assign(accessory)
        #expect(await putBack.value?.registryID == 1)

        try await Task.sleep(for: .milliseconds(200))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    // MARK: - The User's Own Edits

    @Test("An attach the user asked for is remembered, and taken off every other VM")
    func aUserAttachRewritesTheRuleLibraryWide() throws {
        let service = MockUSBAccessoryService()
        let first = makeInstance(sessionID: UUID(), named: "First")
        let second = makeInstance(sessionID: UUID(), named: "Second")
        let roster = StubVMInstanceRoster([first, second])
        let coordinator = try makeCoordinator(makeLifecycle(service), roster: roster)
        defer { withExtendedLifetime(coordinator) {} }
        let accessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "0373")
        try pair(accessory, with: first)

        coordinator.userAttached(accessory, to: second)

        // Moving a device between guests is a detach then an attach, and the
        // rewrite is what makes one key name one VM.
        #expect(first.usbPairings.isEmpty)
        #expect(second.usbPairings.pairings.map(\.key) == [accessory.identity?.key])
    }

    @Test("A detach the user asked for forgets the rule and the device stays with the Mac")
    func aUserDetachForgetsAndSuppressesTheEcho() async throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-A@1")
        try pair(accessory, with: instance)
        service.accessories.append(accessory)

        coordinator.userReleased(accessory, from: instance)
        #expect(instance.usbPairings.isEmpty)

        // The detach resets the device, so macOS hands the same stick back
        // under a new registry ID. It must neither be re-attached nor prompted
        // for, or the user could never take it away.
        service.accessories.removeAll()
        service.assignComposing(registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")
        #expect(recorder.requests.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    @Test("The suppression is spent once, so a later replug is offered again")
    func theReleaseTokenIsSpentOnce() throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let recorder = PromptRecorder()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.onPairingNeeded = { recorder.requests.append($0) }
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-A@1")
        coordinator.userReleased(accessory, from: instance)

        service.assignComposing(registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")
        #expect(recorder.requests.isEmpty)

        // A token that outlived its own echo would silence the device for good.
        service.accessories.removeAll()
        service.assignComposing(registryID: 3, serial: "0373", receptacle: "hub/Port-A@1")
        #expect(recorder.requests.count == 1)
    }

    // MARK: - VM Start

    @Test("A guest that becomes attachable takes back the accessories paired with it")
    func aStartTakesBackItsAccessories() async throws {
        let service = MockUSBAccessoryService()
        let instance = makeStoppedInstance()
        let other = makeStoppedInstance(named: "Other")
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance, other]))
        defer { withExtendedLifetime(coordinator) {} }
        instance.onSessionBecameAttachable = { [weak coordinator] in
            coordinator?.sessionBecameAttachable(instance)
        }
        let mine = MockUSBAccessoryService.accessory(registryID: 1, serial: "A")
        let theirs = MockUSBAccessoryService.accessory(registryID: 2, serial: "B")
        try pair(mine, with: instance)
        try pair(theirs, with: other)
        service.accessories = [mine, theirs]

        instance.beginSessionContext()
        instance.enter(.running(sessionID: UUID()))

        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [1])
    }

    @Test("Resuming a paused guest does not run the take-back again")
    func aResumeIsNotAnEdge() async throws {
        let service = MockUSBAccessoryService()
        let instance = makeStoppedInstance()
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        instance.onSessionBecameAttachable = { [weak coordinator] in
            coordinator?.sessionBecameAttachable(instance)
        }
        let accessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "A")
        try pair(accessory, with: instance)
        service.accessories = [accessory]
        let sessionID = UUID()
        instance.beginSessionContext()
        instance.enter(.running(sessionID: sessionID))
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }

        // Both phases are attachable, so neither transition is an edge.
        instance.settle(.livePaused(sessionID: sessionID), for: sessionID)
        instance.settle(.running(sessionID: sessionID), for: sessionID)

        try await Task.sleep(for: .milliseconds(200))
        #expect(service.attachedRegistryIDs == [1])
    }

    // MARK: - Waiting for the VM to Settle

    @Test("An automatic attach waits for the operation already in flight")
    func anAutomaticAttachWaitsForTheOperationToSettle() async throws {
        let service = MockUSBAccessoryService()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        let lifecycle = makeLifecycle(service)
        let coordinator = try makeCoordinator(lifecycle, roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        let first = MockUSBAccessoryService.accessory(registryID: 1, serial: "A")
        let second = MockUSBAccessoryService.accessory(registryID: 2, serial: "B")
        service.accessories.append(first)
        try pair(second, with: instance)

        service.suspendNextAttach = true
        let held = Task { try await lifecycle.attachUSBAccessory(1, to: instance, for: sessionID) }
        await service.attachStarted()

        // The lifecycle rejects a concurrent operation rather than queueing it,
        // so an attach issued without the wait would be refused outright and
        // this accessory would never reach the guest.
        service.assign(second)
        service.resumeAttach()
        _ = try await held.value

        try await waitForChange { instance.liveUSBAccessories.count == 2 }
        #expect(service.attachedRegistryIDs == [1, 2])
    }

    @Test("A guest that goes away under the wait keeps the accessory with the host")
    func aVMThatStopsUnderTheWaitHoldsTheAccessory() async throws {
        let service = MockUSBAccessoryService()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        let lifecycle = makeLifecycle(service)
        let coordinator = try makeCoordinator(lifecycle, roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }
        let first = MockUSBAccessoryService.accessory(registryID: 1, serial: "A")
        let second = MockUSBAccessoryService.accessory(registryID: 2, serial: "B")
        service.accessories.append(first)
        try pair(second, with: instance)

        service.suspendNextAttach = true
        let held = Task { try? await lifecycle.attachUSBAccessory(1, to: instance, for: sessionID) }
        await service.attachStarted()
        service.assign(second)

        // This is what a save does: it ejects every passthrough device and
        // leaves the VM suspended. The wait is what makes the coordinator see
        // that rather than the phase the save started from.
        instance.tearDownSession(restingAt: .suspended)
        service.resumeAttach()
        _ = await held.value

        try await Task.sleep(for: .milliseconds(200))
        #expect(service.attachedRegistryIDs == [1])
    }
}
