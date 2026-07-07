import Foundation
import os

/// Drop-in replacement for `os.Logger` that, in addition to writing to the
/// local log store, can forward each emission to a remote sink — the guest
/// agent installs one that relays to the host over vsock; the host app leaves
/// it `nil`, so logs there stay local.
///
/// Construction matches `os.Logger`:
///
///     private static let logger = KernovaLogger(
///         subsystem: "app.kernova.macosagent",
///         category: "GuestAgent"
///     )
///
/// Call-site syntax is identical too — including privacy attributes:
///
///     logger.notice("VM '\(name, privacy: .public)' started")
///     logger.debug("retrying in \(seconds, privacy: .public)s")
///
/// Forwarding goes through `forwardingSink`. If the sink is `nil` (the host,
/// or the guest before its vsock connection is wired) the local emission
/// still happens and the forward is best-effort dropped.
///
/// Lives in `KernovaKit` so the guest agent and the host app share one
/// logging surface; the guest-specific vsock relay is injected via
/// `forwardingSink` rather than referenced directly.
public struct KernovaLogger: Sendable {
    /// The `os.Logger` subsystem, also tagged on each forwarded record.
    public let subsystem: String
    /// The `os.Logger` category, also tagged on each forwarded record.
    public let category: String
    private let osLogger: Logger

    /// Creates a logger for a subsystem/category, matching `os.Logger`.
    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.osLogger = Logger(subsystem: subsystem, category: category)
    }

    // MARK: - Forwarding sink

    /// Receives every emission for forwarding to a remote destination:
    /// `(level, subsystem, category, wire-rendered message)`.
    public typealias ForwardingSink =
        @Sendable (
            _ level: Kernova_V1_LogRecord.Level,
            _ subsystem: String,
            _ category: String,
            _ message: String
        ) -> Void

    // RATIONALE: nonisolated(unsafe) mirrors the prior `VsockLogBridge`
    // pattern — assigned once during synchronous startup, before any
    // background `Task` fires a log line, and read-only thereafter. There is
    // no concurrent write contention; the guest's underlying connection
    // handles its own thread safety.
    /// Process-wide forwarding sink the guest agent installs to relay each
    /// emission to the host over vsock; the host app leaves it `nil`.
    nonisolated(unsafe) public static var forwardingSink: ForwardingSink?

    // MARK: - Levels

    /// Logs at `.debug` and forwards the wire form.
    public func debug(_ message: KernovaLogMessage) {
        osLogger.debug("\(message.localRendered, privacy: .public)")
        forward(level: .debug, message: message.wireRendered)
    }

    /// Logs at `.info` and forwards the wire form.
    public func info(_ message: KernovaLogMessage) {
        osLogger.info("\(message.localRendered, privacy: .public)")
        forward(level: .info, message: message.wireRendered)
    }

    /// Logs at `.notice` and forwards the wire form.
    public func notice(_ message: KernovaLogMessage) {
        osLogger.notice("\(message.localRendered, privacy: .public)")
        forward(level: .notice, message: message.wireRendered)
    }

    /// Logs at `.warning` and forwards the wire form.
    public func warning(_ message: KernovaLogMessage) {
        osLogger.warning("\(message.localRendered, privacy: .public)")
        forward(level: .warning, message: message.wireRendered)
    }

    /// Logs at `.error` and forwards the wire form.
    public func error(_ message: KernovaLogMessage) {
        osLogger.error("\(message.localRendered, privacy: .public)")
        forward(level: .error, message: message.wireRendered)
    }

    /// Logs at `.fault` and forwards the wire form.
    public func fault(_ message: KernovaLogMessage) {
        osLogger.fault("\(message.localRendered, privacy: .public)")
        forward(level: .fault, message: message.wireRendered)
    }

    // MARK: - Forwarding

    private func forward(
        level: Kernova_V1_LogRecord.Level,
        message: String
    ) {
        Self.forwardingSink?(level, subsystem, category, message)
    }
}
