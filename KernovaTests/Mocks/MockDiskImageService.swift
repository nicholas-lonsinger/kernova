import Foundation
@testable import Kernova

/// No-op mock for `DiskImageProviding` that tracks calls without creating real disk images.
final class MockDiskImageService: DiskImageProviding, @unchecked Sendable {

    var createDiskImageCallCount = 0
    var lastCreatedSizeInGB: Int?

    // MARK: - Error Injection

    var createDiskImageError: (any Error)?

    func createDiskImage(at url: URL, sizeInGB: Int) async throws {
        createDiskImageCallCount += 1
        if let error = createDiskImageError { throw error }
        lastCreatedSizeInGB = sizeInGB
    }

    func physicalSize(of url: URL) throws -> UInt64 {
        0
    }
}
