import Foundation
import KernovaProtocol
import os

/// Forwards guest-emitted log records to the host on `KernovaVsockPort.log`
/// (49153). Connection lifecycle is delegated to `VsockGuestClient`; this
/// class layers log-specific buffering, hello/flush sequencing, and inbound
/// drain on top.
///
/// `forwardLog` is safe to call from any thread. When the channel is down,
/// frames are buffered in a bounded ring (oldest dropped first) and flushed
/// once the next Hello succeeds.
final class VsockHostConnection: @unchecked Sendable {

    // RATIONALE: Same as `VsockGuestClient` — keep this class's diagnostics
    // local to the guest's `os.Logger`. Routing them through `KernovaLogger`
    // would forward them via this same connection, risking a feedback loop
    // where a write failure logs an event that schedules another send
    // through the broken channel.
    private static let logger = Logger(subsystem: "com.kernova.agent", category: "VsockHostConnection")

    /// Maximum number of `LogRecord` frames buffered while the channel is
    /// down. Older entries are dropped first.
    ///
    /// Sized for the bursty pre-connect window: agent boot can take 30s+
    /// from VM-start to first vsock connect on macOS, and clipboard activity
    /// from `VsockGuestClipboardAgent` may push `.debug` traffic that could
    /// fill a smaller buffer well before Hello lands. 256 frames at
    /// ~200 bytes apiece is ~50 KiB of bounded memory.
    private static let logBufferLimit = 256

    private let client: VsockGuestClient

    private let lock = NSLock()
    private var pendingLogs: [Frame] = []

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
    /// next Hello succeeds. Returns `true` when the frame was handed to a
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

    /// Appends a frame to the pre-connect ring, dropping the oldest entries
    /// once the cap is exceeded. Used both for the "no live channel" path
    /// and the "live channel write failed" path so a transient send error
    /// doesn't lose the record.
    private func bufferFrame(_ frame: Frame) {
        lock.withLock {
            pendingLogs.append(frame)
            if pendingLogs.count > Self.logBufferLimit {
                pendingLogs.removeFirst(pendingLogs.count - Self.logBufferLimit)
            }
        }
    }

    // MARK: - Per-connection serve

    private func serveLogChannel(_ channel: VsockChannel) async {
        sendHello(on: channel)
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

    /// Drains `pendingLogs` onto a live channel. On a mid-flush send failure
    /// the channel is dead — but the unflushed remainder is re-enqueued at
    /// the head of `pendingLogs` (ordered before any newly-added frames so
    /// chronological order is preserved) so the next successful reconnect
    /// retries them. The buffer cap is re-applied after re-enqueue, so a
    /// chronic flush failure won't grow memory unbounded.
    private func flushPendingLogs(on channel: VsockChannel) {
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

    private func sendHello(on channel: VsockChannel) {
        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["log.records.v1"]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
                $0.agentVersion = Self.embeddedAgentVersion
            }
        }

        do {
            try channel.send(hello)
        } catch {
            Self.logger.warning("Failed to send Hello: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let embeddedAgentVersion: String = {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "unknown"
        }
        return version
    }()
}
