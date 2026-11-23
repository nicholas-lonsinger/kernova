import Foundation

@testable import KernovaCore

@MainActor
final class MockRemovableMediaDeviceService: RemovableMediaAttaching {
    var attachCallCount = 0
    var detachCallCount = 0
    var attachError: (any Error)?
    var detachError: (any Error)?
    var lastAttachedReadOnly: Bool?

    func attach(
        diskImagePath: String,
        attaching file: URL?,
        readOnly: Bool,
        desiredUUID: UUID?,
        to instance: VMInstance
    ) async throws -> RemovableMediaDeviceInfo {
        attachCallCount += 1
        lastAttachedReadOnly = readOnly
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
