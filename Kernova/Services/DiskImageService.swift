import Foundation
import os

/// Creates ASIF (Apple Sparse Image Format) disk images for VM storage by copying
/// pre-built templates bundled with the app.
///
/// ASIF is a macOS 26 disk image format with near-native SSD performance.
/// Physical size on disk is proportional to actual data written, making it
/// space-efficient for VM storage (e.g., a 100 GB image starts at ~4 MB).
///
/// Templates are stored in `Resources/DiskTemplates/` at fixed sizes. On APFS,
/// `FileManager.copyItem` uses `clonefile()` for a near-instant copy-on-write clone.
struct DiskImageService: Sendable {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "DiskImageService")

    /// The available template disk sizes in GB, matching bundled ASIF images.
    static let templateSizes = [25, 50, 100, 150, 200, 500, 1000, 2000, 3000, 4000]

    /// Creates an ASIF sparse disk image at the specified URL by copying a bundled template.
    ///
    /// - Parameters:
    ///   - url: The file URL where the disk image should be created.
    ///   - sizeInGB: The virtual capacity of the disk image in gigabytes. Must match
    ///     one of the bundled template sizes in ``templateSizes``.
    func createDiskImage(at url: URL, sizeInGB: Int) async throws {
        Self.logger.info("Creating ASIF disk image: \(sizeInGB) GB at \(url.lastPathComponent)")

        guard let templateURL = Bundle.main.url(
            forResource: "BlankDisk-\(sizeInGB)GB",
            withExtension: "asif"
        ) else {
            throw DiskImageError.creationFailed("No template disk image for \(sizeInGB) GB")
        }

        try FileManager.default.copyItem(at: templateURL, to: url)

        Self.logger.notice("Successfully created ASIF disk image at \(url.lastPathComponent)")
    }

    /// Returns the physical (actual) size of a disk image on disk.
    func physicalSize(of url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(values.totalFileAllocatedSize ?? 0)
    }
}

// MARK: - DiskImageProviding

extension DiskImageService: DiskImageProviding {}

// MARK: - Errors

enum DiskImageError: LocalizedError {
    case creationFailed(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let output):
            "Failed to create disk image: \(output)"
        }
    }
}
