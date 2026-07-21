import Foundation
import KernovaKit
import os

/// Forwards guest-emitted log records to the host on `KernovaVsockPort.log`
/// (49153).
///
/// Connection lifecycle is delegated to `VsockGuestClient`; this
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
    private static let logger = Logger(subsystem: "app.kernova.macosagent", category: "VsockHostConnection")

    /// Maximum number of `LogRecord` frames buffered while the channel is
    /// down.
    ///
    /// Older entries are dropped first.
    ///
    /// Sized for the bursty pre-connect window: agent boot can take 30s+
    /// from VM-start to first vsock connect on macOS, and clipboard activity
    /// from `VsockGuestClipboardAgent` may push `.debug` traffic that could
    /// fill a smaller buffer well before the log channel comes up. Records now
    /// buffer from process start — the `.undecided` policy state buffers rather
    /// than drops until the host's first `PolicyUpdate` (#598) — so this window
    /// is actually reachable, not just from policy-enable onward. 256 frames
    /// at ~200 bytes apiece is ~50 KiB of bounded memory.
    static let logBufferLimit = 256

    private let client: VsockGuestClient

    let lock = NSLock()
    var pendingLogs: [Frame] = []

    /// Whether the host has decided log forwarding yet, and if so, its verdict.
    ///
    /// Policy defaults to disabled until the host's first `PolicyUpdate` arrives
    /// (the install/boot window, up to 30 s+), so a plain on/off flag would drop
    /// every record emitted before that handshake — defeating the pre-connect
    /// ring's whole purpose. The `.undecided` state buffers those records
    /// instead, deferring the send/drop verdict to the first `setEnabled(_:)`
    /// (#598).
    private enum ForwardingPolicy {
        case undecided
        case enabled
        case disabled
    }

    /// Current forwarding policy, guarded by `lock`. `.undecided` until the host's
    /// first `PolicyUpdate`; then `.enabled`/`.disabled` per `setEnabled(_:)`.
    private var policy: ForwardingPolicy = .undecided

    /// Lock-guarded read of the forwarding policy for the main-thread menu.
    ///
    /// Renders the "Log Forwarding: enabled/disabled" line; the lock makes the
    /// cross-thread read safe (`policy` is mutated from the off-main policy
    /// callback). `.undecided` reads as not-yet-enabled.
    var isLogForwardingEnabled: Bool {
        lock.withLock { policy == .enabled }
    }

    init() {
        self.client = VsockGuestClient(port: KernovaVsockPort.log, label: "log")
        // Default-disabled: pause the reconnect loop until the host sends its
        // first `PolicyUpdate(logForwardingEnabled: true)`.
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
    /// This is also the first decision that resolves the initial `.undecided`
    /// policy, so `undecided → enabled/disabled` is always a transition (never a
    /// no-op). When enabling: resumes the loop so the next connect happens within
    /// `retryInterval`, flushing any records buffered during the undecided
    /// window. When disabling: closes any active channel via the underlying
    /// client, discards buffered log frames (including undecided-era records — an
    /// explicit "off" ships nothing retroactively, preserving the privacy intent)
    /// so the host doesn't get a flood on the next enable, and pauses the
    /// reconnect loop. Idempotent — a repeat call with the already-decided value
    /// is a no-op.
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
    /// When no
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
        // Drop the frame entirely once host policy has explicitly disabled
        // forwarding — not just buffer it for later. The user's intent is "stop
        // sending, don't fill a pipe to flush on the next enable".
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

        // No policy decision yet: buffer the frame so the install/boot-window
        // records survive to the first `PolicyUpdate` instead of being dropped
        // (#598). `timestampMs` is stamped above (forward time), so chronology
        // survives the deferred flush; a `.disabled` verdict later clears these.
        guard policy == .enabled else {
            bufferFrameUnlessDisabled(frame)
            return false
        }

        if let live = client.liveChannel {
            do {
                try live.send(frame)
                return true
            } catch {
                // Send failed — channel is likely dead. Buffer the frame so
                // it gets flushed on the next reconnect rather than lost.
                bufferFrameUnlessDisabled(frame)
                return false
            }
        }

        bufferFrameUnlessDisabled(frame)
        return false
    }

    /// Appends a frame to the pre-connect ring, dropping oldest entries once the cap is exceeded.
    func bufferFrame(_ frame: Frame) {
        lock.withLock { appendToRingLocked(frame) }
    }

    /// Buffers `frame` unless host policy has meanwhile gone explicitly `.disabled`.
    ///
    /// `forwardLog` samples the policy, builds the frame, and only then buffers,
    /// so a `setEnabled(false)` landing in between would clear `pendingLogs` and
    /// then find this frame appended behind it — shipping a record on the next
    /// enable that an explicit "off" was meant to discard. Re-checking under the
    /// same lock hold as the append makes that discard authoritative.
    private func bufferFrameUnlessDisabled(_ frame: Frame) {
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
