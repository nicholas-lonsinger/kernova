import Foundation
import Testing

@testable import Kernova

/// What the coordinator does with an assignment: nothing, except keep the
/// guests' records honest.
@Suite("USB Accessory Coordinator Tests", .admissionGated)
@MainActor
struct USBAccessoryCoordinatorTests {
    private func makeLifecycle(_ service: MockUSBAccessoryService) -> VMLifecycleCoordinator {
        VMLifecycleCoordinator(
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            usbAccessoryService: service)
    }

    /// The coordinator under test.
    ///
    /// Nothing else holds it — the closures it installs on the service capture
    /// it weakly, as the one real owner is `VMLibraryViewModel` — so a test
    /// that discards it is testing a coordinator that answers nothing, and
    /// every "leaves it alone" assertion passes for the wrong reason. Callers
    /// keep the returned value alive for the length of the test.
    private func makeCoordinator(
        _ lifecycle: VMLifecycleCoordinator, roster: any VMInstanceRoster
    ) throws -> USBAccessoryCoordinator {
        try #require(USBAccessoryCoordinator(lifecycle: lifecycle, roster: roster))
    }

    private func makeInstance(sessionID: UUID, named name: String = "USB VM") -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, phase: .running(sessionID: sessionID))
        instance.beginSessionContext()
        return instance
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
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            usbAccessoryService: nil)
        #expect(USBAccessoryCoordinator(lifecycle: lifecycle, roster: StubVMInstanceRoster()) == nil)
    }

    @Test("Holds a newly assigned accessory rather than attaching it to the one running guest")
    func anAssignmentIsHeld() async throws {
        let service = MockUSBAccessoryService()
        let instance = makeInstance(sessionID: UUID())
        let coordinator = try makeCoordinator(
            makeLifecycle(service), roster: StubVMInstanceRoster([instance]))
        defer { withExtendedLifetime(coordinator) {} }

        service.assign(MockUSBAccessoryService.accessory(registryID: 1, serial: "A"))

        // Exactly one candidate used to be reason enough. It no longer is:
        // every assignment waits for the user to place it.
        #expect(service.attachedRegistryIDs.isEmpty)
        #expect(instance.liveUSBAccessories.isEmpty)
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
}
