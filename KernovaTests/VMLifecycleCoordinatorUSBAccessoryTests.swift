import Foundation
import Testing

@testable import Kernova

/// What the coordinator guarantees about passthrough accessories: that an edit
/// is serialized against the save paths, that a session lost under an attach
/// takes the device back, that a device VZ already lost still clears, and that
/// a warm snapshot ends once its files are written, owing back what it had to
/// take off.
@Suite("VMLifecycleCoordinator USB Accessory Tests", .caseScoped)
@MainActor
struct VMLifecycleCoordinatorUSBAccessoryTests {
    private func makeCoordinator(
        accessories: MockUSBAccessoryService = MockUSBAccessoryService(),
        virtualization: any VirtualizationProviding = MockVirtualizationService()
    ) -> (VMLifecycleCoordinator, MockUSBAccessoryService) {
        let coordinator = makeTestLifecycle(
            virtualization: virtualization, usbAccessoryService: accessories)
        return (coordinator, accessories)
    }

    /// The libraries this test's VMs are registered in, and the accessory
    /// coordinator routing each one's arrivals, kept for the test's length: a
    /// VM reads whether its build passes accessories through from the library
    /// it belongs to, and the service holds the coordinator's callback weakly.
    private let libraries = Libraries()

    private final class Libraries {
        private var held: [VMLibrary] = []
        private var routers: [USBAccessoryCoordinator] = []

        func keep(_ library: VMLibrary, routedBy router: USBAccessoryCoordinator?) {
            held.append(library)
            if let router { routers.append(router) }
        }
    }

    /// A library over `coordinator`, with the accessory coordinator the app
    /// wires beside it, answering each VM's attachable edge as the app does.
    private func makeLibrary(on coordinator: VMLifecycleCoordinator) -> VMLibrary {
        let library = makeWiredLibrary(lifecycle: coordinator)
        let router = USBAccessoryCoordinator(
            lifecycle: coordinator, roster: library, holders: library.accessoryHolders,
            pairings: library)
        library.onSessionBecameAttachable = { [weak router] instance in
            router?.sessionBecameAttachable(instance) ?? []
        }
        libraries.keep(library, routedBy: router)
        return library
    }

    private func makeInstance(sessionID: UUID, on coordinator: VMLifecycleCoordinator) -> VMInstance {
        let library = makeLibrary(on: coordinator)
        let instance = library.registerFixture(name: "USB VM", phase: .running(sessionID: sessionID))
        instance.beginSessionContextForTesting()
        return instance
    }

    // MARK: - Serialization against the save paths

    @Test("An accessory edit claims the VM, so a save cannot start underneath it")
    func anEditHoldsTheOperationLock() async throws {
        let (coordinator, service) = makeCoordinator()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 1))

        #expect(instance.phase.operation == nil)
        try await coordinator.attachUSBAccessory(1, to: instance, for: sessionID)
        // The operation ends with the edit, which is what lets the save that
        // follows it run at all.
        #expect(instance.phase == .running(sessionID: sessionID))
        #expect(instance.liveUSBAccessories.count == 1)
    }

    @Test("A second edit is refused while one is in flight")
    func aConcurrentEditIsRefused() async throws {
        let (coordinator, service) = makeCoordinator()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 1))
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 2))
        service.suspendNextAttach = true

        async let first: Void = {
            _ = try? await coordinator.attachUSBAccessory(1, to: instance, for: sessionID)
        }()
        try await service.attachStarted()

        await #expect(throws: VMAdmissionRefusal(refusal: .busy(.attachingUSB(registryID: 1)))) {
            try await coordinator.attachUSBAccessory(2, to: instance, for: sessionID)
        }

        service.resumeAttach()
        await first
    }

    // MARK: - The launched attach a follow-up runs

    @Test("A launched attach holds the VM from its admission and resolves the outcome it was handed")
    func aLaunchedAttachResolvesItsOutcome() async throws {
        let (coordinator, service) = makeCoordinator()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 1))
        let outcome = VMOutcome()
        let held = HeldAccessories()

        try coordinator.launchUSBAccessoryAttach(
            1, to: instance, for: sessionID, resolving: outcome
        ) { _, attached in
            held.registryIDs.append(attached.accessory.registryID)
        }

        #expect(instance.phase.operation?.kind == .attachingUSB(registryID: 1))
        #expect(instance.phase.operation?.outcome === outcome)
        try await outcome.value()
        #expect(held.registryIDs == [1])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [1])
        #expect(instance.phase == .running(sessionID: sessionID))
    }

    @Test("A launched attach refused at admission throws, commits nothing, and leaves its outcome to its owner")
    func aRefusedLaunchedAttachCommitsNothing() async throws {
        let (coordinator, service) = makeCoordinator()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 1))
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 2))
        service.suspendNextAttach = true
        let first = VMOutcome()
        try coordinator.launchUSBAccessoryAttach(1, to: instance, for: sessionID, resolving: first)
        try await service.attachStarted()

        let second = VMOutcome()
        #expect(throws: VMAdmissionRefusal(refusal: .busy(.attachingUSB(registryID: 1)))) {
            try coordinator.launchUSBAccessoryAttach(
                2, to: instance, for: sessionID, resolving: second)
        }
        #expect(instance.phase.operation?.outcome === first)

        service.resumeAttach()
        try await first.value()
        #expect(service.attachedRegistryIDs == [1])
    }

    // MARK: - One accessory, one holder

    /// Two running VMs in one library, so both attach against the same
    /// holder map.
    private func makeTwoInstances(
        on coordinator: VMLifecycleCoordinator
    ) -> (VMLibrary, (VMInstance, UUID), (VMInstance, UUID)) {
        let library = makeLibrary(on: coordinator)
        let firstSession = UUID()
        let first = library.registerFixture(name: "First", phase: .running(sessionID: firstSession))
        first.beginSessionContextForTesting()
        let secondSession = UUID()
        let second = library.registerFixture(
            name: "Second", phase: .running(sessionID: secondSession))
        second.beginSessionContextForTesting()
        return (library, (first, firstSession), (second, secondSession))
    }

    @Test("An attach in flight holds its accessory, so another VM's attach of it is refused as held")
    func anAttachInFlightHoldsItsAccessory() async throws {
        let (coordinator, service) = makeCoordinator()
        let (library, (first, firstSession), (second, secondSession)) = makeTwoInstances(
            on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 5))
        service.suspendNextAttach = true

        async let attach: Void = {
            _ = try? await coordinator.attachUSBAccessory(5, to: first, for: firstSession)
        }()
        try await service.attachStarted()

        // Reserved in the admission of the first attach, before VZ was asked.
        #expect(library.accessoryHolders.holder(of: 5) === first)
        await #expect(throws: VMAdmissionRefusal(refusal: .accessoryHeld(by: first))) {
            try await coordinator.attachUSBAccessory(5, to: second, for: secondSession)
        }
        // Refused before its operation committed, and before VZ was asked.
        #expect(second.phase == .running(sessionID: secondSession))
        #expect(service.attachedRegistryIDs == [5])

        service.resumeAttach()
        await attach
        #expect(first.liveUSBAccessories.map(\.accessory.registryID) == [5])
        #expect(second.liveUSBAccessories.isEmpty)
    }

    @Test("An attach that fails frees its accessory at the operation's end")
    func aFailedAttachFreesItsAccessory() async throws {
        let (coordinator, service) = makeCoordinator()
        let (library, (first, firstSession), (second, secondSession)) = makeTwoInstances(
            on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 5))
        service.attachError = USBAccessoryError.noUSBController

        await #expect(throws: USBAccessoryError.noUSBController) {
            try await coordinator.attachUSBAccessory(5, to: first, for: firstSession)
        }
        #expect(library.accessoryHolders.heldRegistryIDs.isEmpty)

        service.attachError = nil
        try await coordinator.attachUSBAccessory(5, to: second, for: secondSession)
        #expect(library.accessoryHolders.holder(of: 5) === second)
    }

    @Test("An accessory another VM took while a capture had it off the guest stays with that VM")
    func anOwedReturnLeavesAnAccessoryAnotherVMTook() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let (library, (first, firstSession), (second, secondSession)) = makeTwoInstances(
            on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: first, for: firstSession)
        virtualization.onTakeSnapshot = captureEjecting(service: service)
        let gate = GatedStep()
        virtualization.takeSnapshotGate = gate

        async let snapshot: Void = {
            _ = try? await coordinator.takeSnapshot(
                first, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }()
        try await gate.waitUntilEntered()
        // The stick comes back under a new handle while the capture holds the
        // first VM, so its return waits behind the capture — and the other VM
        // takes it meanwhile.
        service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "0373"))
        #expect(first.activity.queuedFollowUpCountForTesting == 1)
        try await coordinator.attachUSBAccessory(11, to: second, for: secondSession)
        gate.release()
        await snapshot

        // The owed attach was decided when the capture freed the VM, and
        // refused as held: nothing was asked of VZ for it.
        #expect(first.activity.queuedFollowUpCountForTesting == 0)
        #expect(service.attachedRegistryIDs == [9, 11])
        #expect(library.accessoryHolders.holder(of: 11) === second)
        #expect(first.liveUSBAccessories.isEmpty)
        #expect(first.phase == .running(sessionID: firstSession))
    }

    // MARK: - A session lost under the attach

    @Test("An attach whose session goes away hands the device back rather than recording it")
    func anAttachThatLosesItsSessionReleasesTheDevice() async throws {
        let (coordinator, service) = makeCoordinator()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 7))
        let deviceID = UUID()
        service.nextDeviceID = deviceID
        service.suspendNextAttach = true

        async let attach: Void = {
            _ = try? await coordinator.attachUSBAccessory(7, to: instance, for: sessionID)
        }()
        try await service.attachStarted()
        // The guest goes away while VZ is capturing the device.
        instance.handleSessionEvent(.guestDidStop)
        service.resumeAttach()
        await attach

        // VZ captured it, so leaving it captured by a VM nothing holds would
        // strand the user's hardware — it goes back.
        #expect(service.detachedDeviceIDs == [deviceID])
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    // MARK: - Detach

    @Test("A detach of a device VZ no longer holds still clears the entry and does not throw")
    func detachOfAnAlreadyGoneDeviceSucceeds() async throws {
        let (coordinator, service) = makeCoordinator()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 3))
        let attached = try await coordinator.attachUSBAccessory(3, to: instance, for: sessionID)
        service.detachError = USBAccessoryError.deviceNotFound

        try await coordinator.detachUSBAccessory(
            deviceID: attached.deviceID, from: instance, for: sessionID)

        #expect(instance.liveUSBAccessories.isEmpty)
    }

    @Test("A detach that fails for another reason is reported")
    func detachFailureIsReported() async throws {
        let (coordinator, service) = makeCoordinator()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 3))
        let attached = try await coordinator.attachUSBAccessory(3, to: instance, for: sessionID)
        service.detachError = USBAccessoryError.noUSBController

        await #expect(throws: USBAccessoryError.self) {
            try await coordinator.detachUSBAccessory(
                deviceID: attached.deviceID, from: instance, for: sessionID)
        }
    }

    // MARK: - A warm snapshot owes back what it took off

    /// Runs a warm capture's real sweep over `session`, and has macOS
    /// withdraw each stick it took off while the reset the detach causes runs
    /// — it comes back later as a new IORegistry node, same serial, different
    /// `registryID`.
    private func captureEjecting(
        service: MockUSBAccessoryService,
        session: MockSnapshotSession = MockSnapshotSession(guestState: .running)
    ) -> @MainActor (borrowing VMCaptureContext) async throws -> Void {
        { context in
            let before = context.operation.instance.liveUSBAccessories
            defer {
                let still = Set(context.operation.instance.liveUSBAccessories.map(\.deviceID))
                let ejected = Set(
                    before.filter { !still.contains($0.deviceID) }.map(\.accessory.registryID))
                service.accessories.removeAll { ejected.contains($0.registryID) }
            }
            try await VirtualizationService.detachUSBAccessories(
                owingReturns: context, session: session)
        }
    }

    /// Which VM the library owes the return of the accessory carrying
    /// `serial`, as `MockUSBAccessoryService.accessory` composes its identity.
    private func owedTo(_ serial: String, in instance: VMInstance) throws -> VMInstance? {
        let identity = try #require(
            MockUSBAccessoryService.accessory(registryID: 0, serial: serial).identity)
        return instance.peers?.accessoryHolders.owedReturn(of: identity)
    }

    @Test("An accessory back during a capture is re-attached, under its new handle, as the capture frees the VM")
    func anArrivalDuringACaptureAttachesAfterIt() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(service: service)
        let gate = GatedStep()
        virtualization.takeSnapshotGate = gate

        let snapshot = Task {
            try await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }
        try await gate.waitUntilEntered()
        service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "0373"))
        // The capture holds the VM, so the return waits behind it.
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)
        #expect(service.attachedRegistryIDs == [9])

        service.suspendNextAttach = true
        gate.release()
        _ = try await snapshot.value
        // The capture's own ending admitted the attach: no other request could
        // be decided against the VM in between.
        #expect(instance.phase.operation?.kind == .attachingUSB(registryID: 11))
        try await service.attachStarted()
        service.resumeAttach()
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [9, 11])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [11])
        #expect(instance.phase == .running(sessionID: sessionID))
    }

    @Test("A capture ends when its files are written, so a Pause right after it is admitted")
    func aCaptureDoesNotWaitForItsAccessories() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(service: service)

        _ = try await coordinator.takeSnapshot(
            instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
        ) { _, _ in }

        // Nothing has come back, and nothing holds the VM waiting for it.
        #expect(instance.phase == .running(sessionID: sessionID))
        try await coordinator.pause(instance)
        #expect(instance.phase == .livePaused(sessionID: sessionID))

        // The stick arrives later and still goes back on the guest.
        service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "0373"))
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [9, 11])
        #expect(instance.phase == .livePaused(sessionID: sessionID))
    }

    @Test("Every accessory a capture took off goes back as it arrives")
    func twoAccessoriesGoBackAsEachArrives() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "AAA"))
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 10, serial: "BBB"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        try await coordinator.attachUSBAccessory(10, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(service: service)

        _ = try await coordinator.takeSnapshot(
            instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
        ) { _, _ in }
        service.assign(MockUSBAccessoryService.accessory(registryID: 12, serial: "BBB"))
        try await waitForChange { instance.liveUSBAccessories.count == 1 }
        service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "AAA"))
        try await waitForChange { instance.liveUSBAccessories.count == 2 }

        #expect(service.attachedRegistryIDs == [9, 10, 12, 11])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [12, 11])
    }

    @Test("A snapshot owes nothing back for an accessory nothing durable identifies")
    func anUnidentifiableAccessoryIsNotOwed() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(service: service)

        _ = try await coordinator.takeSnapshot(
            instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
        ) { _, _ in }
        service.assign(MockUSBAccessoryService.accessory(registryID: 11))

        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        #expect(instance.phase == .running(sessionID: sessionID))
        #expect(service.attachedRegistryIDs == [9])
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    @Test("A guest that goes away before its accessory comes back leaves it with the host")
    func aTeardownDropsWhatTheGuestWasOwed() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        let accessory = MockUSBAccessoryService.accessory(registryID: 9, serial: "0373")
        let identity = try #require(accessory.identity)
        service.accessories.append(accessory)
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(service: service)
        _ = try await coordinator.takeSnapshot(
            instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
        ) { _, _ in }
        let holders = try #require(instance.peers?.accessoryHolders)
        #expect(holders.owedReturn(of: identity) === instance)

        instance.handleSessionEvent(.guestDidStop)
        #expect(holders.owedReturn(of: identity) == nil)

        service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "0373"))
        #expect(service.attachedRegistryIDs == [9])
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    // MARK: - A capture that failed ejected the same hardware

    @Test("A capture that failed still gets back what it took off")
    func aFailedCaptureGetsItsAccessoriesBack() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        let eject = captureEjecting(service: service)
        virtualization.onTakeSnapshot = { context in
            try await eject(context)
            #expect(try self.owedTo("0373", in: instance) === instance)
            // Back before the capture has even failed.
            service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "0373"))
        }
        virtualization.takeSnapshotError = VMSnapshotError.snapshotMissingSavedState

        await #expect(throws: VMSnapshotError.self) {
            try await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }

        // The snapshot is gone and the guest is still running, so the user's
        // hardware goes back where it was.
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [9, 11])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [11])
    }

    @Test("A sweep that threw part-way owes back exactly what it took off, and gets it back")
    func aPartialSweepOwesOnlyTheEjected() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        for (registryID, serial) in [(9, "AAA"), (10, "BBB"), (12, "CCC")] {
            service.accessories.append(
                MockUSBAccessoryService.accessory(registryID: UInt64(registryID), serial: serial))
            service.nextDeviceID = UUID()
            try await coordinator.attachUSBAccessory(
                UInt64(registryID), to: instance, for: sessionID)
        }
        // The second detach throws: the first is off, the second and the
        // third are still on the guest.
        let session = MockSnapshotSession(guestState: .running)
        let second = try #require(instance.liveUSBAccessories.dropFirst().first)
        await session.setDetachError(
            VMSessionError.usbControllerUnavailable, forDeviceID: second.deviceID)
        virtualization.onTakeSnapshot = captureEjecting(service: service, session: session)

        await #expect(throws: VMSessionError.self) {
            try await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }

        #expect(try owedTo("AAA", in: instance) === instance)
        #expect(try owedTo("BBB", in: instance) == nil)
        #expect(try owedTo("CCC", in: instance) == nil)
        service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "AAA"))
        try await waitForChange { instance.liveUSBAccessories.count == 3 }
        #expect(service.attachedRegistryIDs == [9, 10, 12, 11])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [10, 12, 11])
    }

    @Test("A capture that fails before its sweep owes nothing back")
    func aCaptureThatFailsBeforeItsSweepOwesNothing() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.takeSnapshotError = VMSnapshotError.snapshotMissingSavedState

        await #expect(throws: VMSnapshotError.self) {
            try await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }

        #expect(try owedTo("0373", in: instance) == nil)
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [9])
    }

    // MARK: - One follow-up per request

    @Test("A paired accessory back during a capture is attached once, though the capture's end also finds it owed")
    func aPairedReturnIsQueuedOnce() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        let accessory = MockUSBAccessoryService.accessory(registryID: 9, serial: "0373")
        var pairings = instance.usbPairings
        pairings.upsert(try #require(USBAccessoryPairing.make(for: accessory)))
        instance.seedUSBPairings(pairings)
        service.accessories.append(accessory)
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(service: service)
        let gate = GatedStep()
        virtualization.takeSnapshotGate = gate

        let snapshot = Task {
            try await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }
        try await gate.waitUntilEntered()
        service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "0373"))
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)

        service.suspendNextAttach = true
        gate.release()
        _ = try await snapshot.value
        // The capture's end is also the VM's attachable edge, which answers
        // the paired accessory; that attach joined the queued one rather than
        // waiting behind it to be refused as held.
        #expect(instance.phase.operation?.kind == .attachingUSB(registryID: 11))
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        try await service.attachStarted()
        service.resumeAttach()
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [9, 11])
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
    }
}

/// The accessories a launched attach reported holding, in order.
@MainActor
private final class HeldAccessories {
    var registryIDs: [UInt64] = []
}
