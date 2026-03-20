import Foundation
import os

/// Creates ASIF (Apple Sparse Image Format) disk images for VM storage.
///
/// ASIF is a macOS 26 disk image format with near-native SSD performance.
/// Physical size on disk is proportional to actual data written, making it
/// space-efficient for VM storage (e.g., a 100 GB image starts at < 1 GB).
struct DiskImageService: Sendable {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "DiskImageService")

    /// Creates an ASIF sparse disk image at the specified URL.
    ///
    /// - Parameters:
    ///   - url: The file URL where the disk image should be created.
    ///   - sizeInGB: The virtual capacity of the disk image in gigabytes.
    func createDiskImage(at url: URL, sizeInGB: Int) async throws {
        Self.logger.info("Creating ASIF disk image: \(sizeInGB) GB at \(url.lastPathComponent)")

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = [
            "image", "create", "blank",
            "--fs", "none",
            "--format", "ASIF",
            "--size", "\(sizeInGB)g",
            url.path(percentEncoded: false)
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                if terminatedProcess.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: DiskImageError.creationFailed(output))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

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
