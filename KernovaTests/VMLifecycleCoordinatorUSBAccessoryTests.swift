import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// What the coordinator guarantees about passthrough accessories: that an edit
/// is serialized against the save paths, that a session lost under an attach
/// takes the device back, and that a device VZ already lost still clears.
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

    // MARK: - An arrival under a capture

    @Test("A paired accessory that arrives during a capture is attached in the step the capture ends")
    func aPairedArrivalAttachesAsTheCaptureEnds() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        let accessory = MockUSBAccessoryService.accessory(registryID: 11, serial: "0373")
        var pairings = instance.usbPairings
        pairings.upsert(try #require(USBAccessoryPairing.make(for: accessory)))
        instance.seedUSBPairings(pairings)
        let gate = GatedStep()
        virtualization.takeSnapshotGate = gate

        let snapshot = Task {
            try await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }
        try await gate.waitUntilEntered()
        // The capture holds the VM, so the accessory waits with the host.
        service.assign(accessory)
        #expect(service.attachedRegistryIDs.isEmpty)

        service.suspendNextAttach = true
        gate.release()
        _ = try await snapshot.value
        // The capture's end is the VM's attachable edge, which takes the
        // paired accessory back before any other request is decided.
        #expect(instance.phase.operation?.kind == .attachingUSB(registryID: 11))
        try await service.attachStarted()
        service.resumeAttach()
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs == [11])
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
    }
}

/// The accessories a launched attach reported holding, in order.
@MainActor
private final class HeldAccessories {
    var registryIDs: [UInt64] = []
}
