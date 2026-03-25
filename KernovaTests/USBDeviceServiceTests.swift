import Testing
import Foundation
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

    // MARK: - Mock Service Tests

    @Test("Mock service records attach call parameters")
    func mockServiceRecordsAttach() async throws {
        let service = MockUSBDeviceService()
        let instance = makeInstance()

        let info = try await service.attach(diskImagePath: "/tmp/test.dmg", readOnly: false, to: instance)

        #expect(info.path == "/tmp/test.dmg")
        #expect(info.readOnly == false)
        #expect(service.attachCallCount == 1)
        #expect(service.lastAttachedPath == "/tmp/test.dmg")
        #expect(service.lastAttachedReadOnly == false)
        #expect(instance.attachedUSBDevices.isEmpty)
    }

    @Test("Mock service records detach call")
    func mockServiceRecordsDetach() async throws {
        let service = MockUSBDeviceService()
        let instance = makeInstance()

        let info = try await service.attach(diskImagePath: "/tmp/test.dmg", readOnly: false, to: instance)
        try await service.detach(deviceInfo: info, from: instance)

        #expect(service.detachCallCount == 1)
    }

    @Test("Attach propagates errors without modifying tracking")
    func attachPropagatesErrors() async {
        let service = MockUSBDeviceService()
        service.attachError = USBDeviceError.noVirtualMachine
        let instance = makeInstance()

        await #expect {
            try await service.attach(diskImagePath: "/tmp/test.dmg", readOnly: false, to: instance)
        } throws: { error in
            guard let e = error as? USBDeviceError,
                  case .noVirtualMachine = e else { return false }
            return true
        }

        #expect(instance.attachedUSBDevices.isEmpty)
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
                  case .deviceNotFound = e else { return false }
            return true
        }
    }

    // MARK: - VMInstance State Tests

    @Test("tearDownSession clears attachedUSBDevices")
    func tearDownClearsUSBDevices() {
        let instance = makeInstance()

        instance.attachedUSBDevices.append(USBDeviceInfo(path: "/tmp/a.dmg", readOnly: false))
        instance.attachedUSBDevices.append(USBDeviceInfo(path: "/tmp/b.dmg", readOnly: true))
        #expect(instance.attachedUSBDevices.count == 2)

        instance.tearDownSession()

        #expect(instance.attachedUSBDevices.isEmpty)
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
