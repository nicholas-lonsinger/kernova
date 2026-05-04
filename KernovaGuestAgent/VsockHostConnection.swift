import Foundation
import KernovaProtocol
import os

/// Forwards guest-emitted log records to the host on `KernovaVsockPort.log`
/// (49153). Connection lifecycle is delegated to `VsockGuestClient`; this
/// class layers log-specific buffering and inbound drain on top.
///
/// The version handshake and agent liveness live on the always-on control
/// channel (`VsockGuestControlAgent` / `KernovaVsockPort.control`). This class
/// emits only `LogRecord` frames once a connection is established.
///
/// `forwardLog` is safe to call from any thread. When the channel is down,
/// frames are buffered in a bounded ring (oldest dropped first) and flushed
/// once the next connection comes up.
final class VsockHostConnection: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.kernova.agent", category: "VsockHostConnection")

    /// Maximum number of `LogRecord` frames buffered while the channel is
    /// down. Older entries are dropped first.
    ///
    /// Sized for the bursty pre-connect window: agent boot can take 30s+
    /// from VM-start to first vsock connect on macOS, and clipboard activity
    /// from `VsockGuestClipboardAgent` may push `.debug` traffic that could
    /// fill a smaller buffer well before the log channel comes up. 256 frames
    /// at ~200 bytes apiece is ~50 KiB of bounded memory.
    static let logBufferLimit = 256

    private let client: VsockGuestClient

    let lock = NSLock()
    var pendingLogs: [Frame] = []

    init() {
        self.client = VsockGuestClient(port: KernovaVsockPort.log, label: "log")
    }

    /// Begins the connect/serve/reconnect loop. Idempotent.
    func start() {
        client.start { [weak self] channel in
            await self?.serveLogChannel(channel)
        }
    }

    /// Stops the loop, tears down any active channel, and discards the
    /// buffered log records.
    func stop() {
        client.stop()
        lock.withLock { pendingLogs.removeAll(keepingCapacity: false) }
    }

    /// Builds and best-effort sends a `LogRecord` frame to the host. When no
    /// connection is currently active, the frame is buffered (up to
    /// `logBufferLimit` records, oldest dropped first) and flushed once the
    /// next connection comes up. Returns `true` when the frame was handed to a
    /// live channel synchronously.
    @discardableResult
    func forwardLog(
        level: Kernova_V1_LogRecord.Level,
        subsystem: String,
        category: String,
        message: String
    ) -> Bool {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.logRecord = Kernova_V1_LogRecord.with {
            $0.timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
            $0.level = level
            $0.subsystem = subsystem
            $0.category = category
            $0.message = message
        }

        if let live = client.liveChannel {
            do {
                try live.send(frame)
                return true
            } catch {
                // Send failed — channel is likely dead. Buffer the frame so
                // it gets flushed on the next reconnect rather than lost.
                bufferFrame(frame)
                return false
            }
        }

        bufferFrame(frame)
        return false
    }

    /// Appends a frame to the pre-connect ring, dropping oldest entries once the cap is exceeded.
    func bufferFrame(_ frame: Frame) {
        lock.withLock {
            pendingLogs.append(frame)
            if pendingLogs.count > Self.logBufferLimit {
                pendingLogs.removeFirst(pendingLogs.count - Self.logBufferLimit)
            }
        }
    }

    // MARK: - Per-connection serve

    private func serveLogChannel(_ channel: VsockChannel) async {
        flushPendingLogs(on: channel)

        // Drain the inbound stream so we observe EOF / errors. The log
        // channel is one-way today; any inbound message is logged and
        // discarded after a protocol-version check.
        do {
            for try await frame in channel.incoming {
                guard frame.protocolVersion == 1 else {
                    Self.logger.warning(
                        "Dropping inbound frame with unsupported protocol version \(frame.protocolVersion, privacy: .public)"
                    )
                    continue
                }
                Self.logger.debug("Received inbound vsock frame (type: \(String(describing: frame.payload), privacy: .public))")
            }
            Self.logger.notice("Vsock channel closed by host")
        } catch {
            Self.logger.warning("Vsock channel ended with error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-enqueues unflushed frames at the head so chronological order survives a mid-flush failure.
    func flushPendingLogs(on channel: VsockChannel) {
        let drained: [Frame] = lock.withLock {
            let p = pendingLogs
            pendingLogs.removeAll(keepingCapacity: true)
            return p
        }
        guard !drained.isEmpty else { return }

        for (index, frame) in drained.enumerated() {
            do {
                try channel.send(frame)
            } catch {
                let unflushed = Array(drained[index...])
                lock.withLock {
                    pendingLogs.insert(contentsOf: unflushed, at: 0)
                    if pendingLogs.count > Self.logBufferLimit {
                        pendingLogs.removeFirst(pendingLogs.count - Self.logBufferLimit)
                    }
                }
                Self.logger.warning(
                    "Re-enqueued \(unflushed.count, privacy: .public) buffered log frame(s) after flush failure: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }
        Self.logger.debug("Flushed \(drained.count, privacy: .public) buffered log frame(s)")
    }

}
