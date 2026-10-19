import Foundation
import KernovaKit
import KernovaLogging

/// Republishes a guest agent's emitted log records into the host's logging
/// stack so guest log output appears alongside host logs in Console.app.
///
/// One instance manages one `VsockChannel` for the lifetime of one accepted
/// connection and settles when that channel dies under it; `stop()` is
/// idempotent and terminal, so a reconnect is served by a fresh instance.
@MainActor
final class VsockGuestLogService: VsockFeatureService {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VsockGuestLogService")

    private let channel: VsockChannel
    private let emitter: any GuestLogEmitter
    private let label: String

    private var consumeTask: Task<Void, Never>?

    /// Guards the teardown against re-entry: the consume task's tail and the
    /// owner can each reach `settle(reason:)`, and whichever arrives first is
    /// the one that settles.
    private var hasStopped = false

    /// Notified once when the channel dies on its own, never on an
    /// owner-requested `stop()`.
    var onChannelLost: (@MainActor () -> Void)?

    #if DEBUG
    var lifecycleTasksForTesting: [Task<Void, Never>] { [consumeTask].compactMap { $0 } }
    #endif

    /// - Parameters:
    ///   - channel: the channel accepted from the guest's vsock connection.
    ///   - label: human-readable identifier used in host-side diagnostics
    ///     and as the `os.Logger` category for forwarded guest records.
    ///     Typically the VM name.
    ///   - emitter: where to publish translated guest log records. `nil`
    ///     builds an `OSLogGuestLogEmitter` from `label`.
    init(
        channel: VsockChannel,
        label: String,
        emitter: (any GuestLogEmitter)? = nil
    ) {
        self.channel = channel
        self.label = label
        self.emitter = emitter ?? OSLogGuestLogEmitter(label: label)
    }

    /// Begins consuming frames from the channel (idempotent, and a no-op once
    /// the service has settled).
    func start() {
        guard consumeTask == nil, !hasStopped else { return }
        let label = self.label
        let channel = self.channel
        let emitter = self.emitter
        consumeTask = Task { [weak self] in
            await Self.consume(channel: channel, emitter: emitter, label: label)
            // The channel is gone once `consume` returns — the peer closed it,
            // or it spoke on the wrong port and the loop closed it.
            self?.settle(reason: .channelLost)
        }
        Self.logger.log(.info, "Guest log service started for '\(self.label, privacy: .public)'")
    }

    /// Tears the service down at the owner's request.
    ///
    /// The owner is not called back — it already knows. Involuntary channel
    /// death routes through `settle(reason: .channelLost)` instead.
    func stop() {
        settle(reason: .ownerRequested)
    }

    /// Tears the service down, telling the owner when the channel died rather
    /// than being closed on purpose.
    ///
    /// Safe to call from inside the task it cancels: `Task.cancel()` only sets
    /// the cancellation flag, so a caller running inside the consume task's tail
    /// runs this method to completion. The `hasStopped` latch makes
    /// `onChannelLost` fire at most once, and never after an owner teardown has
    /// already settled.
    private func settle(reason: VsockSettleReason) {
        guard !hasStopped else { return }
        hasStopped = true
        consumeTask?.cancel()
        consumeTask = nil
        channel.close()
        // Last, so the owner observes fully-settled state from inside the
        // callback.
        if case .channelLost = reason {
            onChannelLost?()
        }
    }

    private static func consume(
        channel: VsockChannel,
        emitter: any GuestLogEmitter,
        label: String
    ) async {
        do {
            for try await frame in channel.incoming {
                guard handle(frame: frame, emitter: emitter, label: label) else {
                    // Drop the channel rather than keep serving a non-conformant
                    // peer; a conformant agent's reconnect loop re-establishes it.
                    channel.close()
                    break
                }
            }
            logger.log(.info, "Guest log channel closed for '\(label, privacy: .public)'")
        } catch {
            logger.log(
                .warning,
                "Guest log channel ended with error for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Processes one inbound frame; returns `false` when the frame is a
    /// protocol violation that must close the channel.
    private static func handle(
        frame: Frame,
        emitter: any GuestLogEmitter,
        label: String
    ) -> Bool {
        guard frame.protocolVersion == 1 else {
            logger.log(
                .warning,
                "Dropping frame with unsupported protocol version \(frame.protocolVersion, privacy: .public) for '\(label, privacy: .public)'"
            )
            return true
        }
        switch frame.payload {
        case .logRecord(let record):
            emitter.emit(record)
            return true
        case .error(let error):
            logger.log(
                .warning,
                "Guest agent error for '\(label, privacy: .public)': \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
            return true
        case .hello, .heartbeat, .policyUpdate, .clipboardOffer, .clipboardRequest,
            .clipboardRelease, .clipboardTransferRequest, .clipboardTransferReply,
            .dropOffer, .dropComplete, .dropRelease:
            // Hello, Heartbeat, and PolicyUpdate belong on the control channel;
            // clipboard payloads belong on the clipboard channel, drop payloads
            // on the drop channel.
            logger.log(
                .warning,
                "Unexpected payload on log channel for '\(label, privacy: .public)' — wrong port; closing the channel"
            )
            return false
        case .none:
            logger.log(.debug, "Frame with no payload for '\(label, privacy: .public)'")
            return true
        }
    }
}

// MARK: - GuestLogEmitter

/// Receives `LogRecord` payloads forwarded from a guest agent.
protocol GuestLogEmitter: Sendable {
    func emit(_ record: Kernova_V1_LogRecord)
}

/// Republishes guest log records via `KernovaLogger`.
///
/// Each record is emitted at the closest matching host log level, behind a
/// public `[subsystem/category] ` label, with each guest segment keeping the
/// privacy the guest gave it.
struct OSLogGuestLogEmitter: GuestLogEmitter {
    private let logger: KernovaLogger

    /// Emits through a logger with its own subsystem, so guest logs are
    /// filterable separately from host logs, and `label` as its category.
    init(label: String) {
        self.init(logger: KernovaLogger(subsystem: "app.kernova.guest", category: label))
    }

    init(logger: KernovaLogger) {
        self.logger = logger
    }

    func emit(_ record: Kernova_V1_LogRecord) {
        logger.log(
            Self.level(record.level),
            LogMessage(
                segments: [LogSegment(text: "[\(record.subsystem)/\(record.category)] ", isPrivate: false)]
                    + record.segments.map { LogSegment(text: $0.text, isPrivate: $0.private) }))
    }

    private static func level(_ level: Kernova_V1_LogRecord.Level) -> KernovaLogLevel {
        switch level {
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .warning: .warning
        case .error: .error
        case .fault: .fault
        case .unspecified, .UNRECOGNIZED: .notice
        }
    }
}
