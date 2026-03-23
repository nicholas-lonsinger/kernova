import Foundation
import os

/// Creates ASIF (Apple Sparse Image Format) disk images for VM storage by
/// decompressing pre-built templates bundled with the app.
///
/// ASIF is a macOS 26 disk image format with near-native SSD performance.
/// Physical size on disk is proportional to actual data written, making it
/// space-efficient for VM storage (e.g., a 100 GB image starts at ~4 MB).
///
/// Templates are stored lzfse-compressed in `Resources/DiskTemplates/` at fixed
/// sizes (~3 KB each). At VM creation time, the template is decompressed and
/// written to the destination — fully sandbox-safe with no process spawning.
struct DiskImageService: Sendable {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "DiskImageService")

    /// Creates an ASIF sparse disk image at the specified URL by decompressing a bundled template.
    ///
    /// - Parameters:
    ///   - url: The file URL where the disk image should be created.
    ///   - sizeInGB: The virtual capacity of the disk image in gigabytes. Must match
    ///     one of the sizes in ``VMGuestOS/allDiskSizes``.
    func createDiskImage(at url: URL, sizeInGB: Int) async throws {
        Self.logger.info("Creating ASIF disk image: \(sizeInGB, privacy: .public) GB at \(url.lastPathComponent, privacy: .public)")

        guard let templateURL = Bundle.main.url(
            forResource: "BlankDisk-\(sizeInGB)GB.asif",
            withExtension: "lzfse",
            subdirectory: "DiskTemplates"
        ) else {
            throw DiskImageError.creationFailed("No template disk image for \(sizeInGB) GB")
        }

        let destination = url
        try await Task.detached {
            let compressed = try Data(contentsOf: templateURL)
            let decompressed = try (compressed as NSData).decompressed(using: .lzfse) as Data
            try decompressed.write(to: destination)
        }.value

        Self.logger.notice("Successfully created ASIF disk image at \(url.lastPathComponent, privacy: .public)")
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
        case .creationFailed(let reason):
            "Failed to create disk image: \(reason)"
        }
    }
}
