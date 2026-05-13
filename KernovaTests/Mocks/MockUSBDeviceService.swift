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
    var lastAttachedDesiredUUID: UUID?

    func attach(
        diskImagePath: String,
        readOnly: Bool,
        desiredUUID: UUID?,
        to instance: VMInstance
    ) async throws -> USBDeviceInfo {
        attachCallCount += 1
        lastAttachedPath = diskImagePath
        lastAttachedReadOnly = readOnly
        lastAttachedDesiredUUID = desiredUUID
        if let error = attachError { throw error }
        // Honor the desired UUID so callers that pass one (e.g. the disc
        // image hot-swap flow) get back a USBDeviceInfo whose `id` matches
        // what they asked for. Falls back to a fresh UUID when nil.
        let id = desiredUUID ?? UUID()
        return USBDeviceInfo(id: id, path: diskImagePath, readOnly: readOnly)
    }

    func detach(
        deviceInfo: USBDeviceInfo,
        from instance: VMInstance
    ) async throws {
        detachCallCount += 1
        if let error = detachError { throw error }
    }
}
