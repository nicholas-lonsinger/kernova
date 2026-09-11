import Foundation
@testable import Kernova

@MainActor
final class MockRemovableMediaDeviceService: RemovableMediaAttaching {
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
    ) async throws -> RemovableMediaDeviceInfo {
        attachCallCount += 1
        lastAttachedPath = diskImagePath
        lastAttachedReadOnly = readOnly
        lastAttachedDesiredUUID = desiredUUID
        if let error = attachError { throw error }
        // Honor the desired UUID so callers that pass one (e.g. the disk
        // image hot-swap flow) get back a RemovableMediaDeviceInfo whose `id` matches
        // what they asked for. Falls back to a fresh UUID when nil.
        let id = desiredUUID ?? UUID()
        return RemovableMediaDeviceInfo(id: id, path: diskImagePath, readOnly: readOnly)
    }

    func detach(
        deviceInfo: RemovableMediaDeviceInfo,
        from instance: VMInstance
    ) async throws {
        detachCallCount += 1
        if let error = detachError { throw error }
    }
}
