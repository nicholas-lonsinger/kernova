import Foundation
import KernovaKit
import os

/// Forwards guest-emitted log records to the host on `KernovaVsockPort.log`.
///
/// Connection lifecycle is delegated to `VsockGuestClient`; this class layers
/// log-specific buffering and inbound drain on top.
final class VsockHostConnection: @unchecked Sendable {
    private static let logger = Logger(subsystem: "app.kernova.macosagent", category: "VsockHostConnection")

    /// Maximum number of `LogRecord` frames buffered while the channel is down,
    /// oldest dropped first.
    ///
    /// Sized for the bursty pre-connect window: agent boot can take 30 s+ from
    /// VM start to the first vsock connect on macOS.
    static let logBufferLimit = 256

    private let client: any VsockReconnecting

    let lock = NSLock()
    var pendingLogs: [Frame] = []

    /// Whether the host has decided log forwarding yet, and if so, its verdict.
    ///
    /// `.undecided` buffers records rather than dropping them, so the boot
    /// window survives to the host's first `PolicyUpdate`.
    private enum ForwardingPolicy {
        case undecided
        case enabled
        case disabled
    }

    /// Current forwarding policy, guarded by `lock`.
    private var policy: ForwardingPolicy = .undecided

    /// Lock-guarded read of the forwarding policy for the main-thread menu.
    var isLogForwardingEnabled: Bool {
        lock.withLock { policy == .enabled }
    }

    init() {
        self.client = makeVsockGuestClient(port: KernovaVsockPort.log, label: "log")
        // Default-disabled: no connect attempts until the host's first
        // `PolicyUpdate(logForwardingEnabled: true)`.
        self.client.pause()
    }

    /// Begins the connect/serve/reconnect loop (idempotent).
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

    /// Applies a host policy update for log forwarding.
    ///
    /// Enabling resumes the loop, flushing whatever was buffered while the policy
    /// was undecided. Disabling closes the channel and discards the buffer — an
    /// explicit "off" ships nothing retroactively. Idempotent.
    func setEnabled(_ enabled: Bool) {
        let target: ForwardingPolicy = enabled ? .enabled : .disabled
        let needsTransition: Bool = lock.withLock {
            let was = policy
            policy = target
            return was != target
        }
        guard needsTransition else { return }
        if enabled {
            client.resume()
            Self.logger.notice("Log forwarding enabled by host policy")
        } else {
            client.pause()
            lock.withLock { pendingLogs.removeAll(keepingCapacity: false) }
            Self.logger.notice("Log forwarding disabled by host policy")
        }
    }

    /// Builds and best-effort sends a `LogRecord` frame to the host.
    ///
    /// Safe to call from any thread. With no live connection the frame is
    /// buffered and flushed on the next one. Returns `true` only when the frame
    /// was handed to a live channel synchronously.
    @discardableResult
    func forwardLog(
        level: Kernova_V1_LogRecord.Level,
        subsystem: String,
        category: String,
        message: String
    ) -> Bool {
        let policy = lock.withLock { self.policy }
        if policy == .disabled { return false }

        var frame = Frame()
        frame.protocolVersion = 1
        frame.logRecord = Kernova_V1_LogRecord.with {
            $0.timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
            $0.level = level
            $0.subsystem = subsystem
            $0.category = category
            $0.message = message
        }

        // `timestampMs` is stamped above at forward time, so chronology survives
        // a deferred flush.
        guard policy == .enabled else {
            bufferFrameUnlessDisabled(frame)
            return false
        }

        if let live = client.liveChannel {
            do {
                try live.send(frame)
                return true
            } catch {
                bufferFrameUnlessDisabled(frame)
                return false
            }
        }

        bufferFrameUnlessDisabled(frame)
        return false
    }

    /// Appends `frame` to the pre-connect ring unless host policy has meanwhile
    /// gone explicitly `.disabled`.
    ///
    /// `forwardLog` samples the policy before building the frame, so re-checking
    /// under the same lock hold as the append is what keeps a concurrent
    /// `setEnabled(false)` from leaving this frame behind its own buffer clear.
    func bufferFrameUnlessDisabled(_ frame: Frame) {
        lock.withLock {
            guard policy != .disabled else { return }
            appendToRingLocked(frame)
        }
    }

    /// The bounded-ring append itself, for callers already holding `lock`.
    private func appendToRingLocked(_ frame: Frame) {
        pendingLogs.append(frame)
        if pendingLogs.count > Self.logBufferLimit {
            pendingLogs.removeFirst(pendingLogs.count - Self.logBufferLimit)
        }
    }

    // MARK: - Per-connection serve

    private func serveLogChannel(_ channel: VsockChannel) async {
        flushPendingLogs(on: channel)

        // The log channel is one-way; draining is how EOF and errors are seen.
        do {
            for try await frame in channel.incoming {
                guard frame.protocolVersion == 1 else {
                    Self.logger.warning(
                        "Dropping inbound frame with unsupported protocol version \(frame.protocolVersion, privacy: .public)"
                    )
                    continue
                }
                Self.logger.debug(
                    "Received inbound vsock frame (type: \(String(describing: frame.payload), privacy: .public))")
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
