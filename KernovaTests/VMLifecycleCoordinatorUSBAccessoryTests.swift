import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// What the coordinator guarantees about passthrough accessories: that an edit
/// is serialized against the save paths, that a session lost under an attach
/// takes the device back, that a device VZ already lost still clears, and that
/// a warm snapshot puts back what it had to take off.
@Suite("VMLifecycleCoordinator USB Accessory Tests", .admissionGated)
@MainActor
struct VMLifecycleCoordinatorUSBAccessoryTests {
    private func makeCoordinator(
        accessories: MockUSBAccessoryService = MockUSBAccessoryService(),
        virtualization: any VirtualizationProviding = MockVirtualizationService()
    ) -> (VMLifecycleCoordinator, MockUSBAccessoryService) {
        let coordinator = VMLifecycleCoordinator(
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            usbAccessoryService: accessories
        )
        return (coordinator, accessories)
    }

    private func makeInstance(sessionID: UUID) -> VMInstance {
        let config = VMConfiguration(name: "USB VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, phase: .running(sessionID: sessionID))
        instance.beginSessionContext()
        return instance
    }

    // MARK: - Serialization against the save paths

    @Test("An accessory edit claims the VM, so a save cannot start underneath it")
    func anEditHoldsTheOperationLock() async throws {
        let (coordinator, service) = makeCoordinator()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 1))

        #expect(!coordinator.hasActiveOperation(for: instance.id))
        try await coordinator.attachUSBAccessory(1, to: instance, for: sessionID)
        // The claim is released again once the edit settles, which is what lets
        // the save that follows it run at all.
        #expect(!coordinator.hasActiveOperation(for: instance.id))
        #expect(instance.liveUSBAccessories.count == 1)
    }

    @Test("A second edit is refused while one is in flight")
    func aConcurrentEditIsRefused() async throws {
        let (coordinator, service) = makeCoordinator()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 1))
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 2))
        service.suspendNextAttach = true

        async let first: Void = {
            _ = try? await coordinator.attachUSBAccessory(1, to: instance, for: sessionID)
        }()
        await service.attachStarted()

        await #expect(throws: VMLifecycleCoordinator.LifecycleError.self) {
            try await coordinator.attachUSBAccessory(2, to: instance, for: sessionID)
        }

        service.resumeAttach()
        await first
    }

    // MARK: - A session lost under the attach

    @Test("An attach whose session goes away hands the device back rather than recording it")
    func anAttachThatLosesItsSessionReleasesTheDevice() async throws {
        let (coordinator, service) = makeCoordinator()
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 7))
        let deviceID = UUID()
        service.nextDeviceID = deviceID
        service.suspendNextAttach = true

        async let attach: Void = {
            _ = try? await coordinator.attachUSBAccessory(7, to: instance, for: sessionID)
        }()
        await service.attachStarted()
        // The guest goes away while VZ is capturing the device.
        instance.tearDownSession(restingAt: .stopped)
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
        let instance = makeInstance(sessionID: sessionID)
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
        let instance = makeInstance(sessionID: sessionID)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 3))
        let attached = try await coordinator.attachUSBAccessory(3, to: instance, for: sessionID)
        service.detachError = USBAccessoryError.noUSBController

        await #expect(throws: USBAccessoryError.self) {
            try await coordinator.detachUSBAccessory(
                deviceID: attached.deviceID, from: instance, for: sessionID)
        }
    }

    // MARK: - A warm snapshot puts back what it took off

    /// Stands in for what a warm capture does to the host's hardware: the
    /// guest's records go, and the stick itself comes back to macOS as a new
    /// IORegistry node — same serial, different `registryID`.
    private func captureEjecting(
        _ instance: VMInstance, for sessionID: UUID, service: MockUSBAccessoryService,
        reassigningAs registryID: UInt64?, serial: String
    ) -> @MainActor () -> Void {
        { [weak instance] in
            guard let instance else { return }
            for item in instance.liveUSBAccessories {
                instance.forgetAttachedAccessory(deviceID: item.deviceID, for: sessionID)
            }
            service.accessories.removeAll()
            guard let registryID else { return }
            service.assign(
                MockUSBAccessoryService.accessory(registryID: registryID, serial: serial))
        }
    }

    @Test("A snapshot re-attaches the accessory the capture had to eject, under its new handle")
    func aSnapshotPutsAccessoriesBack() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: 11, serial: "0373")

        let snapshot = VMSnapshot(name: "Snap", kind: .warm)
        try await coordinator.takeSnapshot(
            instance, snapshot: snapshot, store: MockVMSnapshotStore())

        // The handle it went off under names nothing now; it goes back on under
        // the one macOS assigned it after the reset.
        #expect(service.attachedRegistryIDs == [9, 11])
        #expect(service.awaitedIdentities.map(\.key) == ["0403:6001:0100:0373"])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [11])
    }

    @Test("A snapshot waits for a re-assignment that has not arrived yet")
    func aSnapshotWaitsForTheAccessoryToComeBack() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        // The capture ejects it and macOS has not handed it back yet.
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: nil, serial: "0373")

        async let snapshot: Void = {
            try? await coordinator.takeSnapshot(
                instance, snapshot: VMSnapshot(name: "Snap", kind: .warm),
                store: MockVMSnapshotStore())
        }()
        // Event-driven both ways: the assignment lands only once the put-back
        // is actually parked on it.
        try await service.waitStarted.wait { service.parkedWaitCount > 0 }
        service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "0373"))
        await snapshot

        #expect(service.attachedRegistryIDs == [9, 11])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [11])
    }

    @Test("A snapshot leaves an accessory off the guest when it is never assigned back")
    func anAccessoryThatNeverReturnsStaysOff() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: nil, serial: "0373")
        service.answersMissingAccessoryImmediately = true

        try await coordinator.takeSnapshot(
            instance, snapshot: VMSnapshot(name: "Snap", kind: .warm),
            store: MockVMSnapshotStore())

        // The snapshot the user asked for is written; the hardware is simply
        // where a surprise unplug would have left it.
        #expect(service.attachedRegistryIDs == [9])
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    @Test("A snapshot does not try to put back an accessory nothing durable identifies")
    func anUnidentifiableAccessoryIsNotPutBack() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: nil, serial: "0373")

        try await coordinator.takeSnapshot(
            instance, snapshot: VMSnapshot(name: "Snap", kind: .warm),
            store: MockVMSnapshotStore())

        #expect(service.awaitedIdentities.isEmpty)
        #expect(service.attachedRegistryIDs == [9])
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    @Test("A re-attach whose guest goes away under it hands the device back")
    func aReattachThatLosesItsSessionReleasesTheDevice() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: 11, serial: "0373")
        let reattachedDeviceID = UUID()
        service.nextDeviceID = reattachedDeviceID
        service.suspendNextAttach = true

        async let snapshot: Void = {
            try? await coordinator.takeSnapshot(
                instance, snapshot: VMSnapshot(name: "Snap", kind: .warm),
                store: MockVMSnapshotStore())
        }()
        await service.attachStarted()
        // The guest goes away while VZ is capturing the device for the put-back.
        instance.tearDownSession(restingAt: .stopped)
        service.resumeAttach()
        await snapshot

        // Recording it would name a session nothing holds, and leaving it
        // captured would strand the user's hardware — so it goes back.
        #expect(service.detachedDeviceIDs == [reattachedDeviceID])
        #expect(instance.liveUSBAccessories.isEmpty)
    }
}
