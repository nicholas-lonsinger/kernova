import Foundation

@testable import KernovaCore

/// No-op mock for `DiskImageProviding` that tracks calls without creating real disk images.
@MainActor
final class MockDiskImageService: DiskImageProviding {
    nonisolated init() {}

    var lastCreatedSizeInGB: Int?
    var lastCreatedDiskImageURL: URL?

    // MARK: - Error Injection

    var createDiskImageError: (any Error)?

    func createDiskImage(at url: URL, sizeInGB: Int) async throws {
        lastCreatedDiskImageURL = url
        if let error = createDiskImageError { throw error }
        lastCreatedSizeInGB = sizeInGB
    }
}
