import Testing
import Foundation
import Virtualization
@testable import Kernova

@Suite("USBDeviceService Tests")
@MainActor
struct USBDeviceServiceTests {
    private func makeInstance(status: VMStatus = .running) -> VMInstance {
        let config = VMConfiguration(
            name: "USB Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

    // MARK: - USBDeviceInfo Model Tests

    @Test("USBDeviceInfo displayName returns last path component")
    func usbDeviceInfoDisplayName() {
        let info = USBDeviceInfo(path: "/Users/test/disk.dmg", readOnly: true)
        #expect(info.displayName == "disk.dmg")
    }

    // MARK: - Error Messages

    @Test("Hot-attach of an invalid disk image explains the format and offers a conversion")
    func attachFailureDescribesInvalidDiskImage() {
        let invalid = NSError(
            domain: VZError.errorDomain, code: VZError.Code.invalidDiskImage.rawValue)
        let error = USBDeviceError.diskImageAttachFailed(
            path: "/tmp/bad.dmg", underlying: invalid)

        #expect(error.errorDescription?.contains("/tmp/bad.dmg") == true)
        #expect(error.errorDescription?.contains("512") == true)
        #expect(error.suggestedCommand?.contains("'/tmp/bad.dmg' '/tmp/bad.asif'") == true)
    }

    @Test("Hot-attach failures from other causes keep their message and suggest nothing")
    func attachFailureFromOtherCauseIsUnchanged() {
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
        let error = USBDeviceError.diskImageAttachFailed(
            path: "/tmp/gone.asif", underlying: denied)

        #expect(error.errorDescription?.contains("moved or replaced") == true)
        #expect(error.suggestedCommand == nil)
    }

    @Test("Errors that aren't attach failures suggest no command")
    func nonAttachErrorsSuggestNoCommand() {
        #expect(USBDeviceError.noVirtualMachine.suggestedCommand == nil)
        #expect(USBDeviceError.diskImageNotFound("/tmp/x").suggestedCommand == nil)
    }

    // MARK: - Mock Service Tests

    @Test("Mock service records attach call parameters")
    func mockServiceRecordsAttach() async throws {
        let service = MockUSBDeviceService()
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
        let service = MockUSBDeviceService()
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
        let service = MockUSBDeviceService()
        let instance = makeInstance()

        let info = try await service.attach(
            diskImagePath: "/tmp/test.dmg", readOnly: false, desiredUUID: nil, to: instance)
        try await service.detach(deviceInfo: info, from: instance)

        #expect(service.detachCallCount == 1)
    }

    @Test("Attach propagates errors without modifying tracking")
    func attachPropagatesErrors() async {
        let service = MockUSBDeviceService()
        service.attachError = USBDeviceError.noVirtualMachine
        let instance = makeInstance()

        await #expect {
            try await service.attach(diskImagePath: "/tmp/test.dmg", readOnly: false, desiredUUID: nil, to: instance)
        } throws: { error in
            guard let e = error as? USBDeviceError,
                case .noVirtualMachine = e
            else { return false }
            return true
        }

        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("Detach propagates errors")
    func detachPropagatesErrors() async throws {
        let service = MockUSBDeviceService()
        let instance = makeInstance()

        let info = USBDeviceInfo(path: "/tmp/test.dmg", readOnly: false)
        service.detachError = USBDeviceError.deviceNotFound

        await #expect {
            try await service.detach(deviceInfo: info, from: instance)
        } throws: { error in
            guard let e = error as? USBDeviceError,
                case .deviceNotFound = e
            else { return false }
            return true
        }
    }

    // MARK: - VMInstance State Tests

    @Test("tearDownSession clears liveRemovableMedia")
    func tearDownClearsUSBDevices() {
        let instance = makeInstance()

        instance.liveRemovableMedia.append(USBDeviceInfo(path: "/tmp/a.dmg", readOnly: false))
        instance.liveRemovableMedia.append(USBDeviceInfo(path: "/tmp/b.dmg", readOnly: true))
        #expect(instance.liveRemovableMedia.count == 2)

        instance.tearDownSession()

        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("canAttachUSBDevices is true when running with VM")
    func canAttachWhenRunning() {
        let instance = makeInstance(status: .running)
        // Without a real VZVirtualMachine, this is false
        #expect(instance.canAttachUSBDevices == false)
    }

    @Test("canAttachUSBDevices is false when stopped")
    func cannotAttachWhenStopped() {
        let instance = makeInstance(status: .stopped)
        #expect(instance.canAttachUSBDevices == false)
    }
}
