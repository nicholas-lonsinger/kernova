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
        virtualization: any VirtualizationProviding = MockVirtualizationService(),
        returnTimeout: Duration = .seconds(5)
    ) -> (VMLifecycleCoordinator, MockUSBAccessoryService) {
        let coordinator = makeTestLifecycle(
            virtualization: virtualization, usbAccessoryService: accessories,
            usbAccessoryReturnTimeout: returnTimeout)
        return (coordinator, accessories)
    }

    /// The libraries this test's VMs are registered in, kept for the test's
    /// length: a VM reads whether its build passes accessories through from
    /// the library it belongs to.
    private let libraries = Libraries()

    private final class Libraries {
        private var held: [VMLibrary] = []
        func keep(_ library: VMLibrary) { held.append(library) }
    }

    private func makeInstance(sessionID: UUID, on coordinator: VMLifecycleCoordinator) -> VMInstance {
        let instance = VMInstanceFixture.make(
            name: "USB VM", phase: .running(sessionID: sessionID))
        libraries.keep(makeWiredLibrary(holding: [instance], lifecycle: coordinator))
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
        await service.attachStarted()

        await #expect(throws: VMAdmissionRefusal(refusal: .busy(.attachingUSB(registryID: 1)))) {
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
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 7))
        let deviceID = UUID()
        service.nextDeviceID = deviceID
        service.suspendNextAttach = true

        async let attach: Void = {
            _ = try? await coordinator.attachUSBAccessory(7, to: instance, for: sessionID)
        }()
        await service.attachStarted()
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
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: 11, serial: "0373")

        let snapshot = VMSnapshotCaptureRequest(name: "Snap")
        _ = try await coordinator.takeSnapshot(
            instance, mode: .live, snapshot: snapshot
        ) { _, _ in }

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
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        // The capture ejects it and macOS has not handed it back yet.
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: nil, serial: "0373")

        async let snapshot: Void = {
            _ = try? await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
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
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: nil, serial: "0373")
        service.answersMissingAccessoryImmediately = true

        _ = try await coordinator.takeSnapshot(
            instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
        ) { _, _ in }

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
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: nil, serial: "0373")

        _ = try await coordinator.takeSnapshot(
            instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
        ) { _, _ in }

        #expect(service.awaitedIdentities.isEmpty)
        #expect(service.attachedRegistryIDs == [9])
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    // MARK: - One bounded wait for all of them

    @Test("Every ejected accessory is waited for at once, not one after another")
    func theWaitsForTwoAccessoriesRunTogether() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "AAA"))
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 10, serial: "BBB"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        try await coordinator.attachUSBAccessory(10, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: nil, serial: "AAA")

        async let snapshot: Void = {
            _ = try? await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }()
        // Both waits parked at once is the thing under test: a put-back that
        // waited one at a time could never have two, and the second one's
        // budget would only start once the first had given up.
        try await service.waitStarted.wait { service.parkedWaitCount == 2 }
        service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "AAA"))
        // The other one never comes back, driven as an event rather than by
        // letting a deadline expire.
        service.abandonPendingWaits()
        await snapshot

        #expect(service.attachedRegistryIDs == [9, 10, 11])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [11])
    }

    @Test("A guest that goes away mid-wait ends the put-back rather than waiting it out")
    func aTeardownMidWaitEndsThePutBack() async throws {
        let virtualization = MockVirtualizationService()
        // Long enough that waiting it out would be unmistakable: the wait has
        // to end on the teardown, not on the deadline.
        let (coordinator, service) = makeCoordinator(
            virtualization: virtualization, returnTimeout: .seconds(30))
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: nil, serial: "0373")

        async let snapshot: Void = {
            _ = try? await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }()
        try await service.waitStarted.wait { service.parkedWaitCount > 0 }
        instance.handleSessionEvent(.guestDidStop)
        let start = ContinuousClock.now
        await snapshot
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(5))
        #expect(service.parkedWaitCount == 0)
        // The accessory macOS hands back afterwards has nowhere to go.
        service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "0373"))
        #expect(service.attachedRegistryIDs == [9])
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    // MARK: - A capture that failed ejected the same hardware

    @Test("A capture that failed still puts back what it took off")
    func aFailedCapturePutsAccessoriesBack() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: 11, serial: "0373")
        virtualization.takeSnapshotError = VMSnapshotError.snapshotMissingSavedState

        await #expect(throws: VMSnapshotError.self) {
            try await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }

        // The snapshot is gone and the guest is still running, so the user's
        // hardware goes back where it was.
        #expect(service.attachedRegistryIDs == [9, 11])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [11])
    }

    @Test("A sweep that threw part-way puts back only what it had already ejected")
    func aPartialSweepPutsBackOnlyTheEjected() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "AAA"))
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 10, serial: "BBB"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        try await coordinator.attachUSBAccessory(10, to: instance, for: sessionID)
        // What a sweep that threw on its second device leaves: the first
        // ejected and forgotten, the second still on the guest.
        virtualization.onTakeSnapshot = { [weak instance] in
            guard let instance, let first = instance.liveUSBAccessories.first else { return }
            instance.forgetAttachedAccessory(deviceID: first.deviceID, for: sessionID)
            service.accessories.removeAll { $0.registryID == 9 }
            service.assign(MockUSBAccessoryService.accessory(registryID: 11, serial: "AAA"))
        }
        virtualization.takeSnapshotError = VMSnapshotError.snapshotMissingSavedState

        await #expect(throws: VMSnapshotError.self) {
            try await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }

        // Only the one the sweep ejected is waited for and put back; the one it
        // never reached is still attached and is not touched.
        #expect(service.awaitedIdentities.map(\.key) == ["0403:6001:0100:AAA"])
        #expect(service.attachedRegistryIDs == [9, 10, 11])
        #expect(instance.liveUSBAccessories.map(\.accessory.registryID) == [10, 11])
    }

    @Test("A re-attach whose guest goes away under it hands the device back")
    func aReattachThatLosesItsSessionReleasesTheDevice() async throws {
        let virtualization = MockVirtualizationService()
        let (coordinator, service) = makeCoordinator(virtualization: virtualization)
        let sessionID = UUID()
        let instance = makeInstance(sessionID: sessionID, on: coordinator)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9, serial: "0373"))
        try await coordinator.attachUSBAccessory(9, to: instance, for: sessionID)
        virtualization.onTakeSnapshot = captureEjecting(
            instance, for: sessionID, service: service, reassigningAs: 11, serial: "0373")
        let reattachedDeviceID = UUID()
        service.nextDeviceID = reattachedDeviceID
        service.suspendNextAttach = true

        async let snapshot: Void = {
            _ = try? await coordinator.takeSnapshot(
                instance, mode: .live, snapshot: VMSnapshotCaptureRequest(name: "Snap")
            ) { _, _ in }
        }()
        await service.attachStarted()
        // The guest goes away while VZ is capturing the device for the put-back.
        instance.handleSessionEvent(.guestDidStop)
        service.resumeAttach()
        await snapshot

        // Recording it would name a session nothing holds, and leaving it
        // captured would strand the user's hardware — so it goes back.
        #expect(service.detachedDeviceIDs == [reattachedDeviceID])
        #expect(instance.liveUSBAccessories.isEmpty)
    }
}
