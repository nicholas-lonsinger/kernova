import Foundation
@testable import Kernova

@MainActor
final class MockUSBDeviceService: USBDeviceProviding {
    var attachCallCount = 0
    var detachCallCount = 0
    var attachError: (any Error)?
    var detachError: (any Error)?
    var lastAttachedPath: String?
    var lastAttachedReadOnly: Bool?

    func attach(
        diskImagePath: String,
        readOnly: Bool,
        to instance: VMInstance
    ) async throws -> USBDeviceInfo {
        attachCallCount += 1
        lastAttachedPath = diskImagePath
        lastAttachedReadOnly = readOnly
        if let error = attachError { throw error }
        let info = USBDeviceInfo(path: diskImagePath, readOnly: readOnly)
        instance.attachedUSBDevices.append(info)
        return info
    }

    func detach(
        deviceInfo: USBDeviceInfo,
        from instance: VMInstance
    ) async throws {
        detachCallCount += 1
        if let error = detachError { throw error }
        instance.attachedUSBDevices.removeAll { $0.id == deviceInfo.id }
    }
}
