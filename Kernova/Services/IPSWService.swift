import Foundation
import Virtualization
import os

/// Fetches and downloads macOS restore images (IPSWs) for macOS guest installation.
struct IPSWService: Sendable {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "IPSWService")

    // MARK: - Protocol Methods

    #if arch(arm64)
    /// Fetches the download URL for the latest supported macOS restore image.
    func fetchLatestRestoreImageURL() async throws -> URL {
        Self.logger.info("Fetching latest supported macOS restore image...")
        let restoreImage = try await VZMacOSRestoreImage.latestSupported
        return restoreImage.url
    }

    /// Downloads a macOS restore image from a remote URL to the specified destination.
    func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double, Int64, Int64) -> Void
    ) async throws {
        Self.logger.info("Downloading restore image from \(remoteURL)")

        // Create the destination file up-front so it's visible in Finder immediately.
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)

        var cleanUpPartial = true
        defer {
            if cleanUpPartial {
                Self.logger.info("Removing partial download at \(destinationURL.lastPathComponent)")
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        let (asyncBytes, response) = try await URLSession.shared.bytes(from: remoteURL)
        let expectedBytes = response.expectedContentLength  // -1 if unknown
        let expected = expectedBytes > 0 ? expectedBytes : Int64.max

        guard let fileHandle = FileHandle(forWritingAtPath: destinationURL.path) else {
            throw IPSWError.downloadFailed("Could not open destination file for writing")
        }
        defer { try? fileHandle.close() }

        let bufferSize = 512 * 1024  // 512 KB
        var buffer = Data(capacity: bufferSize)
        var bytesWritten: Int64 = 0

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= bufferSize {
                try fileHandle.write(contentsOf: buffer)
                bytesWritten += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if expectedBytes > 0 {
                    let written = bytesWritten
                    let fraction = Double(written) / Double(expected)
                    let handler = progressHandler
                    Task { @MainActor in handler(fraction, written, expected) }
                }
            }
        }

        // Flush any remaining bytes
        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
            bytesWritten += Int64(buffer.count)
        }

        if expectedBytes > 0 {
            let written = bytesWritten
            let handler = progressHandler
            Task { @MainActor in handler(1.0, written, expected) }
        }

        cleanUpPartial = false
        Self.logger.info("Restore image downloaded to \(destinationURL.lastPathComponent)")
    }

    /// Loads a restore image from a local IPSW file.
    func loadRestoreImage(from url: URL) async throws -> VZMacOSRestoreImage {
        try await VZMacOSRestoreImage.image(from: url)
    }
    #endif
}

// MARK: - IPSWProviding

extension IPSWService: IPSWProviding {}

// MARK: - Errors

enum IPSWError: LocalizedError {
    case noDownloadURL
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDownloadURL:
            "The restore image does not have a download URL."
        case .downloadFailed(let message):
            "Failed to download restore image: \(message)"
        }
    }
}
