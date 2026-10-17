import CryptoKit
import Foundation

/// Digests a file on disk without holding it in memory.
enum FileDigest {
    /// How much of the file is read per iteration.
    ///
    /// The whole point of this type: an installer image runs to gigabytes, and
    /// `Data(contentsOf:)` would make every byte of it resident.
    static let chunkByteCount = 4 * 1024 * 1024

    /// Minimum interval between progress reports, matching the pacing the
    /// download progress bar is fed at.
    private static let progressInterval: TimeInterval = 0.1

    /// The SHA-256 of the file at `url`, as 64 lowercase hex characters.
    ///
    /// Reads on a detached task, so a multi-gigabyte file does not block the
    /// main actor, and checks for cancellation between chunks.
    /// `progressHandler` reports the fraction read, `0...1`, on the main actor.
    static func sha256(
        of url: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> String {
        let totalBytes =
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let work = Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            var readBytes: Int64 = 0
            var lastReport: TimeInterval = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: chunkByteCount), !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
                readBytes += Int64(chunk.count)

                let now = ProcessInfo.processInfo.systemUptime
                guard totalBytes > 0, now - lastReport >= progressInterval else { continue }
                lastReport = now
                let fraction = min(1, Double(readBytes) / Double(totalBytes))
                // `await MainActor.run`, not a detached `Task`: only awaiting
                // delivers the samples in the order they were produced.
                await MainActor.run { progressHandler(fraction) }
            }
            // Unthrottled, so a file read inside a single throttle window still
            // leaves the caller showing a finished step.
            await MainActor.run { progressHandler(1) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
