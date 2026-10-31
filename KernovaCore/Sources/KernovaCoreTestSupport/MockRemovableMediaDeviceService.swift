import Foundation

@testable import KernovaCore

@MainActor
final class MockRemovableMediaDeviceService: RemovableMediaAttaching {
    var attachCallCount = 0
    var detachCallCount = 0
    var attachError: (any Error)?
    /// Thrown by an attach of that path alone, for a pass whose items fail
    /// differently.
    var attachErrorsByPath: [String: any Error] = [:]
    var detachError: (any Error)?
    var lastAttachedPath: String?
    /// Every path attached, in order.
    var attachedPaths: [String] = []
    var lastAttachedReadOnly: Bool?
    var lastAttachedDesiredUUID: UUID?

    func attach(
        diskImagePath: String,
        attaching file: URL?,
        readOnly: Bool,
        desiredUUID: UUID?,
        to instance: VMInstance
    ) async throws -> RemovableMediaDeviceInfo {
        let attachedPath = file?.path(percentEncoded: false) ?? diskImagePath
        attachCallCount += 1
        lastAttachedPath = attachedPath
        attachedPaths.append(attachedPath)
        lastAttachedReadOnly = readOnly
        lastAttachedDesiredUUID = desiredUUID
        if let error = attachError ?? attachErrorsByPath[attachedPath] { throw error }
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
