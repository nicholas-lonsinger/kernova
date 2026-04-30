import Foundation
import KernovaProtocol
import os

/// Republishes a guest agent's emitted log records into the host's logging
/// stack so guest log output appears alongside host logs in Console.app.
///
/// One instance manages one `VsockChannel` for the lifetime of one accepted
/// connection. The service self-terminates when the channel closes (peer
/// disconnect or local teardown).
@MainActor
final class VsockGuestLogService {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VsockGuestLogService")

    private let channel: VsockChannel
    private let emitter: any GuestLogEmitter
    private let label: String

    private var consumeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - channel: the channel accepted from the guest's vsock connection.
    ///   - label: human-readable identifier used in host-side diagnostics
    ///     and as the `os.Logger` category for forwarded guest records.
    ///     Typically the VM name.
    ///   - emitter: where to publish translated guest log records.
    ///     When `nil` (the default), an `OSLogGuestLogEmitter` is built
    ///     using `label` so each VM's forwarded records appear under their
    ///     own `com.kernova.guest:<vmName>` category.
    init(
        channel: VsockChannel,
        label: String,
        emitter: (any GuestLogEmitter)? = nil
    ) {
        self.channel = channel
        self.label = label
        self.emitter = emitter ?? OSLogGuestLogEmitter(label: label)
    }

    /// Begins consuming frames from the channel. Idempotent.
    func start() {
        guard consumeTask == nil else { return }
        let label = self.label
        let channel = self.channel
        let emitter = self.emitter
        consumeTask = Task {
            await Self.consume(channel: channel, emitter: emitter, label: label)
        }
        Self.logger.info("Guest log service started for '\(self.label, privacy: .public)'")
    }

    /// Tears down the consumer task and closes the underlying channel.
    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        channel.close()
    }

    private static func consume(
        channel: VsockChannel,
        emitter: any GuestLogEmitter,
        label: String
    ) async {
        do {
            for try await frame in channel.incoming {
                handle(frame: frame, emitter: emitter, label: label)
            }
            logger.info("Guest log channel closed for '\(label, privacy: .public)'")
        } catch {
            logger.warning("Guest log channel ended with error for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handle(
        frame: Frame,
        emitter: any GuestLogEmitter,
        label: String
    ) {
        switch frame.payload {
        case .hello(let hello):
            logger.notice(
                "Guest agent hello for '\(label, privacy: .public)': service=\(hello.serviceVersion, privacy: .public), agent=\(hello.agentInfo.agentVersion, privacy: .public), os=\(hello.agentInfo.os, privacy: .public) \(hello.agentInfo.osVersion, privacy: .public)"
            )
        case .logRecord(let record):
            emitter.emit(record)
        case .error(let error):
            logger.warning(
                "Guest agent error for '\(label, privacy: .public)': \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .clipboardOffer, .clipboardRequest, .clipboardData, .clipboardRelease:
            // Clipboard payloads belong on the clipboard port; if one arrives
            // here, the guest agent has crossed wires. Log and ignore.
            logger.warning("Unexpected clipboard payload on log channel for '\(label, privacy: .public)'")
        case .none:
            logger.debug("Frame with no payload for '\(label, privacy: .public)'")
        }
    }
}

// MARK: - GuestLogEmitter

/// Receives `LogRecord` payloads forwarded from a guest agent. Production
/// code uses `OSLogGuestLogEmitter`; tests substitute a recording emitter.
protocol GuestLogEmitter: Sendable {
    func emit(_ record: Kernova_V1_LogRecord)
}

/// Republishes guest log records via `os.Logger`. Each record is emitted at
/// the closest matching host log level, with the guest's subsystem and
/// category preserved in the message body.
struct OSLogGuestLogEmitter: GuestLogEmitter {

    private let logger: Logger

    init(label: String) {
        // Use a distinct subsystem so guest logs are filterable separately
        // from host logs in Console.app and `log stream` queries.
        self.logger = Logger(subsystem: "com.kernova.guest", category: label)
    }

    func emit(_ record: Kernova_V1_LogRecord) {
        // RATIONALE: guest records are user-owned content from the user's own
        // VM, not third-party data — emitting as `.public` keeps post-mortem
        // analysis from being littered with `<private>` placeholders.
        let composed = "[\(record.subsystem)/\(record.category)] \(record.message)"

        switch record.level {
        case .debug:
            logger.debug("\(composed, privacy: .public)")
        case .info:
            logger.info("\(composed, privacy: .public)")
        case .notice:
            logger.notice("\(composed, privacy: .public)")
        case .warning:
            logger.warning("\(composed, privacy: .public)")
        case .error:
            logger.error("\(composed, privacy: .public)")
        case .fault:
            logger.fault("\(composed, privacy: .public)")
        case .unspecified, .UNRECOGNIZED:
            logger.log("\(composed, privacy: .public)")
        }
    }
}
