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
    func startsObserving() {
        let service = MockUSBAccessoryService()
        _ = USBAccessoryCoordinator(lifecycle: makeLifecycle(service), roster: StubVMInstanceRoster())
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
        let roster = StubVMInstanceRoster([instance])
        let coordinator = USBAccessoryCoordinator(
            lifecycle: makeLifecycle(service), roster: roster)
        #expect(coordinator != nil)

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
        let coordinator = USBAccessoryCoordinator(
            lifecycle: lifecycle, roster: StubVMInstanceRoster([instance]))
        #expect(coordinator != nil)
        service.accessories.append(
            MockUSBAccessoryService.accessory(registryID: 1, serial: "0373"))
        try await lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
        #expect(instance.liveUSBAccessories.count == 1)

        // The same stick, back from the reset a detach causes: same serial,
        // new IORegistry node.
        service.assign(MockUSBAccessoryService.accessory(registryID: 2, serial: "0373"))

        #expect(instance.liveUSBAccessories.isEmpty)
    }

    @Test("Leaves a guest's record alone when a different accessory arrives")
    func anUnrelatedAssignmentLeavesRecordsAlone() async throws {
        let service = MockUSBAccessoryService()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        let lifecycle = makeLifecycle(service)
        _ = USBAccessoryCoordinator(lifecycle: lifecycle, roster: StubVMInstanceRoster([instance]))
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
        _ = USBAccessoryCoordinator(lifecycle: lifecycle, roster: StubVMInstanceRoster([instance]))
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 1))
        try await lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)

        // Both have a nil identity, and two nils are not a match.
        service.assign(MockUSBAccessoryService.accessory(registryID: 2))

        #expect(instance.liveUSBAccessories.count == 1)
    }
}
