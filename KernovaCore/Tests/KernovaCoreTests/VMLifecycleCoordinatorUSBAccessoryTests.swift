import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

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
            virtualization: virtualization, usbAccessoryPassthrough: .available(accessories))
        return (coordinator, accessories)
    }

    /// The libraries this test's VMs are registered in, and the accessory
    /// coordinator routing each one's arrivals, kept for the test's length: a
    /// VM reads whether its process passes accessories through from the library
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
            lifecycle: coordinator, library: library)
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
            try await VMLiveStateCapture.captureLiveState(
                context, session: session, wasRunning: false, saveFileURL: URL(filePath: "/var/empty/save.vzvmsave")
            ) {}
        }
    }
}

/// The accessories a launched attach reported holding, in order.
@MainActor
private final class HeldAccessories {
    var registryIDs: [UInt64] = []
}
