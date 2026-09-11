import Testing
import Foundation
@testable import Kernova

@Suite("RemovableMediaDeviceService Tests", .admissionGated)
@MainActor
struct RemovableMediaDeviceServiceTests {
    private func makeInstance(phase: VMLifecyclePhase = .running(sessionID: UUID()))
        -> VMInstance
    {
        let config = VMConfiguration(
            name: "USB Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, phase: phase)
    }

    // MARK: - RemovableMediaDeviceInfo Model Tests

    @Test("RemovableMediaDeviceInfo displayName returns last path component")
    func removableMediaDeviceInfoDisplayName() {
        let info = RemovableMediaDeviceInfo(path: "/Users/test/disk.dmg", readOnly: true)
        #expect(info.displayName == "disk.dmg")
    }

    // MARK: - Mock Service Tests

    @Test("Mock service records attach call parameters")
    func mockServiceRecordsAttach() async throws {
        let service = MockRemovableMediaDeviceService()
        let instance = makeInstance()

        let info = try await service.attach(
            diskImagePath: "/tmp/test.dmg", readOnly: false, desiredUUID: nil, to: instance)

        #expect(info.path == "/tmp/test.dmg")
        #expect(info.readOnly == false)
        #expect(service.attachCallCount == 1)
        #expect(service.lastAttachedPath == "/tmp/test.dmg")
        #expect(service.lastAttachedReadOnly == false)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("Mock service honors desiredUUID and records it")
    func mockServiceHonorsDesiredUUID() async throws {
        let service = MockRemovableMediaDeviceService()
        let instance = makeInstance()
        let desired = UUID()

        let info = try await service.attach(
            diskImagePath: "/tmp/test.dmg",
            readOnly: true,
            desiredUUID: desired,
            to: instance
        )

        #expect(info.id == desired)
        #expect(service.lastAttachedDesiredUUID == desired)
    }

    @Test("Mock service records detach call")
    func mockServiceRecordsDetach() async throws {
        let service = MockRemovableMediaDeviceService()
        let instance = makeInstance()

        let info = try await service.attach(
            diskImagePath: "/tmp/test.dmg", readOnly: false, desiredUUID: nil, to: instance)
        try await service.detach(deviceInfo: info, from: instance)

        #expect(service.detachCallCount == 1)
    }

    @Test("Attach propagates errors without modifying tracking")
    func attachPropagatesErrors() async {
        let service = MockRemovableMediaDeviceService()
        service.attachError = RemovableMediaDeviceError.noVirtualMachine
        let instance = makeInstance()

        await #expect {
            try await service.attach(diskImagePath: "/tmp/test.dmg", readOnly: false, desiredUUID: nil, to: instance)
        } throws: { error in
            guard let e = error as? RemovableMediaDeviceError,
                case .noVirtualMachine = e
            else { return false }
            return true
        }

        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("Detach propagates errors")
    func detachPropagatesErrors() async throws {
        let service = MockRemovableMediaDeviceService()
        let instance = makeInstance()

        let info = RemovableMediaDeviceInfo(path: "/tmp/test.dmg", readOnly: false)
        service.detachError = RemovableMediaDeviceError.deviceNotFound

        await #expect {
            try await service.detach(deviceInfo: info, from: instance)
        } throws: { error in
            guard let e = error as? RemovableMediaDeviceError,
                case .deviceNotFound = e
            else { return false }
            return true
        }
    }

    // MARK: - VMInstance State Tests

    @Test("tearDownSession clears liveRemovableMedia")
    func tearDownClearsRemovableMedia() {
        let instance = makeInstance()
        let context = instance.beginSessionContext()

        context.liveRemovableMedia.append(RemovableMediaDeviceInfo(path: "/tmp/a.dmg", readOnly: false))
        context.liveRemovableMedia.append(RemovableMediaDeviceInfo(path: "/tmp/b.dmg", readOnly: true))
        #expect(instance.liveRemovableMedia.count == 2)

        instance.tearDownSession(restingAt: .stopped)

        #expect(context.liveRemovableMedia.isEmpty)
    }

    @Test(
        "canAttachRemovableMedia admits a live VM only at a settled phase",
        arguments: zip(
            [
                VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID()),
                .saving(sessionID: UUID()), .suspended, .stopped,
            ],
            [true, true, false, false, false]))
    func canAttachFollowsLiveSession(phase: VMLifecyclePhase, expected: Bool) {
        let instance = makeInstance(phase: phase)
        #expect(instance.canAttachRemovableMedia == expected)
    }
}
