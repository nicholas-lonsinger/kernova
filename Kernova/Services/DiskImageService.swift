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
    /// - Throws: A ``DiskImageError`` whose case identifies the phase that failed.
    ///   Callers that need to distinguish "no byte was ever written" from "a partial
    ///   file may exist at the destination" can match on ``DiskImageError/writeFailed(_:)``
    ///   specifically — every other case throws before `url` is touched.
    func createDiskImage(at url: URL, sizeInGB: Int) async throws {
        Self.logger.info(
            "Creating ASIF disk image: \(sizeInGB, privacy: .public) GB at \(url.lastPathComponent, privacy: .public)")

        guard
            let templateURL = Bundle.main.url(
                forResource: "BlankDisk-\(sizeInGB)GB.asif",
                withExtension: "lzfse",
                subdirectory: "DiskTemplates"
            )
        else {
            throw DiskImageError.templateMissing(sizeInGB: sizeInGB)
        }

        let destination = url
        try await Task.detached {
            let compressed: Data
            do {
                compressed = try Data(contentsOf: templateURL)
            } catch {
                throw DiskImageError.templateReadFailed(error)
            }

            let decompressed: Data
            do {
                decompressed = try (compressed as NSData).decompressed(using: .lzfse) as Data
            } catch {
                throw DiskImageError.decompressionFailed(error)
            }

            do {
                try decompressed.write(to: destination)
            } catch {
                throw DiskImageError.writeFailed(error)
            }
        }.value

        Self.logger.notice("Successfully created ASIF disk image at \(url.lastPathComponent, privacy: .public)")
    }
}

// MARK: - DiskImageProviding

extension DiskImageService: DiskImageProviding {}

// MARK: - Errors

/// Error cases thrown by ``DiskImageService/createDiskImage(at:sizeInGB:)``.
///
/// The case identifies the phase that failed so callers can decide whether to
/// attempt cleanup at the destination URL. Only ``writeFailed(_:)`` may have
/// touched the destination file; the other cases throw before any write begins.
enum DiskImageError: LocalizedError {
    /// No bundled template matches the requested size.
    case templateMissing(sizeInGB: Int)
    /// Reading the bundled template's compressed bytes failed.
    case templateReadFailed(any Error)
    /// Decompressing the template's lzfse payload failed.
    case decompressionFailed(any Error)
    /// Writing the decompressed image to the destination failed. The destination
    /// may now hold a partial file that the caller should consider cleaning up.
    case writeFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .templateMissing(let sizeInGB):
            "No bundled disk-image template for \(sizeInGB) GB."
        case .templateReadFailed(let underlying):
            "Failed to read bundled disk-image template: \(underlying.localizedDescription)"
        case .decompressionFailed(let underlying):
            "Failed to decompress disk-image template: \(underlying.localizedDescription)"
        case .writeFailed(let underlying):
            "Failed to write disk image: \(underlying.localizedDescription)"
        }
    }
}
