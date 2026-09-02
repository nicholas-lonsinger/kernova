import Foundation
import KernovaTestSupport
@testable import Kernova

/// No-op mock for `DiskImageProviding` that tracks calls without creating real disk images.
final class MockDiskImageService: DiskImageProviding, @unchecked Sendable {
    var createDiskImageCallCount = 0
    var lastCreatedSizeInGB: Int?
    var lastCreatedDiskImageURL: URL?

    // MARK: - Error Injection

    var createDiskImageError: (any Error)?

    // MARK: - Mid-Write Hold

    /// Fires once `createDiskImage` has parked, so a test can observe a create
    /// whose configuration is written and whose disk image is not.
    let parked = AsyncGate()
    private let resumed = AsyncGate()
    private(set) var isParked = false
    private var holdsCreate = false

    /// Parks the next `createDiskImage` call until ``resumeCreateDiskImage()``.
    func holdCreateDiskImage() { holdsCreate = true }

    /// Releases a parked `createDiskImage` call.
    func resumeCreateDiskImage() {
        holdsCreate = false
        resumed.notify()
    }

    func createDiskImage(at url: URL, sizeInGB: Int) async throws {
        createDiskImageCallCount += 1
        lastCreatedDiskImageURL = url
        if holdsCreate {
            isParked = true
            parked.notify()
            try await resumed.wait { !self.holdsCreate }
            isParked = false
        }
        if let error = createDiskImageError { throw error }
        lastCreatedSizeInGB = sizeInGB
    }
}
