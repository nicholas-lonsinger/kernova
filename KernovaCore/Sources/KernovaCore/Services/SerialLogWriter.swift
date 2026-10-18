import Foundation
import KernovaLogging
import Synchronization

/// Appending writer for a VM's on-disk `serial.log` that bounds its size with
/// single-generation rotation: when the file reaches `maxFileSize` it is
/// renamed to `rotatedURL` (replacing any earlier generation) and a fresh log
/// is started, so a bundle never holds more than roughly twice `maxFileSize`
/// of serial history. A pre-existing log already at the cap is cleared at
/// open rather than archived, so the bound holds from the first write.
///
/// The file I/O runs inside one `Mutex`, so `write(_:)` is safe to call from
/// the background queue that drives serial output. After `close()` or a
/// failed open, writes are dropped.
final class SerialLogWriter: Sendable {
    /// Rotation threshold. 10 MB retains dozens of Linux boots' console output
    /// while keeping the worst-case bundle overhead (live file plus one rotated
    /// generation) negligible next to a disk image.
    static let defaultMaxFileSize = 10 * 1024 * 1024

    private let file: Mutex<LogFile>

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "SerialLogWriter")

    init(
        logURL: URL, rotatedURL: URL, label: String,
        maxFileSize: Int = SerialLogWriter.defaultMaxFileSize
    ) {
        var file = LogFile(logURL: logURL, rotatedURL: rotatedURL, maxFileSize: maxFileSize, label: label)
        file.open()
        file.clearIfOversized()
        self.file = Mutex(file)
    }

    /// Appends `data` to the log, rotating once the file reaches `maxFileSize`.
    ///
    /// Safe to call from any thread and never blocks the serial reader. A
    /// write error is logged and the chunk dropped; writes after `close()` or
    /// a failed open are dropped silently.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        file.withLock { $0.write(data) }
    }

    /// Closes the log file. Subsequent writes are dropped. Idempotent.
    func close() {
        file.withLock { $0.close() }
    }

    // Each logging method copies `label` into a local first: `#log`'s escaping
    // autoclosure cannot capture a mutating method's `self`.
    private struct LogFile {
        let logURL: URL
        let rotatedURL: URL
        let maxFileSize: Int
        let label: String

        var handle: FileHandle?
        var fileSize = 0
        /// Set after a failed rotation so the failure logs once, not per chunk.
        var rotationDisabled = false

        init(logURL: URL, rotatedURL: URL, maxFileSize: Int, label: String) {
            self.logURL = logURL
            self.rotatedURL = rotatedURL
            self.maxFileSize = maxFileSize
            self.label = label
        }

        /// A pre-existing log at or over the cap (from a build without one, or
        /// a run whose rotation was disabled) is cleared, not archived: rotating
        /// it whole would carry an arbitrarily large file as `serial.log.1`,
        /// breaking the twice-the-cap bound exactly when it matters most.
        mutating func clearIfOversized() {
            let label = label
            guard fileSize >= maxFileSize else { return }
            do {
                try handle?.truncate(atOffset: 0)
                fileSize = 0
            } catch {
                #log(
                    SerialLogWriter.logger, .warning,
                    "Could not clear oversized serial log for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        mutating func write(_ data: Data) {
            let label = label
            guard let handle else { return }

            do {
                try handle.write(contentsOf: data)
                fileSize += data.count
            } catch {
                #log(
                    SerialLogWriter.logger, .error,
                    "Failed to write to serial log for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                return
            }

            if fileSize >= maxFileSize {
                rotate()
            }
        }

        mutating func open() {
            let label = label
            let path = logURL.path(percentEncoded: false)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            do {
                let newHandle = try FileHandle(forWritingTo: logURL)
                do {
                    fileSize = Int(try newHandle.seekToEnd())
                } catch {
                    #log(
                        SerialLogWriter.logger, .warning,
                        "Could not seek to end of serial log for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                    )
                    fileSize = 0
                }
                handle = newHandle
            } catch {
                #log(
                    SerialLogWriter.logger, .warning,
                    "Could not open serial log for writing for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                handle = nil
                fileSize = 0
            }
        }

        mutating func close() {
            let label = label
            do {
                try handle?.close()
            } catch {
                #log(
                    SerialLogWriter.logger, .warning,
                    "Failed to close serial log file for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
            handle = nil
        }

        /// Moves `serial.log` to `serial.log.1` and reopens a fresh live file. On
        /// failure, keeps appending to the oversized file — losing output would be
        /// worse — and disables further rotation attempts for this writer.
        mutating func rotate() {
            let label = label
            guard !rotationDisabled else { return }
            close()

            do {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: rotatedURL.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: rotatedURL)
                }
                try fileManager.moveItem(at: logURL, to: rotatedURL)
            } catch {
                rotationDisabled = true
                #log(
                    SerialLogWriter.logger, .error,
                    "Serial log rotation failed for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }

            open()
        }
    }
}
