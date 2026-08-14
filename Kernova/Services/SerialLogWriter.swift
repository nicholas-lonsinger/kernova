import Foundation
import os

/// Appending writer for a VM's on-disk `serial.log` that bounds its size with
/// single-generation rotation: when the file reaches `maxFileSize` it is
/// renamed to `serial.log.1` (replacing any earlier generation) and a fresh
/// `serial.log` is started, so a bundle never holds more than roughly twice
/// `maxFileSize` of serial history.
///
/// All file state is guarded by one `NSLock`, so `write(_:)` is safe to call
/// from the background queue that drives serial output. After `close()` or a
/// failed open, writes are dropped.
final class SerialLogWriter: @unchecked Sendable {
    /// Rotation threshold. 10 MB retains dozens of Linux boots' console output
    /// while keeping the worst-case bundle overhead (live file plus one rotated
    /// generation) negligible next to a disk image.
    static let defaultMaxFileSize = 10 * 1024 * 1024

    private let logURL: URL
    private let rotatedURL: URL
    private let maxFileSize: Int
    private let label: String

    private let lock = NSLock()

    // Guarded by `lock`.
    private var handle: FileHandle?
    private var fileSize = 0
    /// Set after a failed rotation so the failure logs once, not per chunk.
    private var rotationDisabled = false

    private static let logger = Logger(subsystem: "app.kernova", category: "SerialLogWriter")

    init(logURL: URL, label: String, maxFileSize: Int = SerialLogWriter.defaultMaxFileSize) {
        self.logURL = logURL
        self.rotatedURL = logURL.appendingPathExtension("1")
        self.maxFileSize = maxFileSize
        self.label = label

        lock.lock()
        defer { lock.unlock() }
        openLocked()
        if fileSize >= maxFileSize {
            rotateLocked()
        }
    }

    /// Appends `data` to the log, rotating once the file reaches `maxFileSize`.
    ///
    /// Safe to call from any thread. A dropped chunk (closed writer, failed
    /// open, or write error) is logged and never blocks the serial reader.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }

        do {
            try handle.write(contentsOf: data)
            fileSize += data.count
        } catch {
            Self.logger.error(
                "Failed to write to serial log for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        if fileSize >= maxFileSize {
            rotateLocked()
        }
    }

    /// Closes the log file. Subsequent writes are dropped. Idempotent.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    // MARK: - Locked helpers

    private func openLocked() {
        let path = logURL.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        do {
            let newHandle = try FileHandle(forWritingTo: logURL)
            do {
                fileSize = Int(try newHandle.seekToEnd())
            } catch {
                Self.logger.warning(
                    "Could not seek to end of serial log for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                fileSize = 0
            }
            handle = newHandle
        } catch {
            Self.logger.warning(
                "Could not open serial log for writing for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            handle = nil
            fileSize = 0
        }
    }

    private func closeLocked() {
        do {
            try handle?.close()
        } catch {
            Self.logger.warning(
                "Failed to close serial log file for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        handle = nil
    }

    /// Moves `serial.log` to `serial.log.1` and reopens a fresh live file. On
    /// failure, keeps appending to the oversized file — losing output would be
    /// worse — and disables further rotation attempts for this writer.
    private func rotateLocked() {
        guard !rotationDisabled else { return }
        closeLocked()

        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: rotatedURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: rotatedURL)
            }
            try fileManager.moveItem(at: logURL, to: rotatedURL)
        } catch {
            rotationDisabled = true
            Self.logger.error(
                "Serial log rotation failed for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }

        openLocked()
    }
}
