import Foundation
import KernovaProtocol
import os

/// Drop-in replacement for `os.Logger` that, in addition to writing to the
/// guest's local log store, forwards each emission as a `LogRecord` frame
/// to the host over vsock (when a connection is active).
///
/// Construction matches `os.Logger`:
///
///     private static let logger = KernovaLogger(
///         subsystem: "com.kernova.agent",
///         category: "GuestAgent"
///     )
///
/// Call-site syntax is identical too — including privacy attributes:
///
///     logger.notice("VM '\(name, privacy: .public)' started")
///     logger.debug("retrying in \(seconds, privacy: .public)s")
///
/// Forwarding goes through `VsockLogBridge.connection`. If the connection
/// is `nil` or not currently connected, the local emission still happens
/// and the forward is best-effort dropped (or buffered, once Phase 3.5.3
/// adds the pre-connect ring buffer).
///
/// NOTE: Lives inside the `KernovaGuestAgent` target. If a future use
/// case needs the same wrapper on the host or in another target, relocate
/// this file (and `KernovaLogMessage.swift`) into the `KernovaProtocol`
/// Swift Package.
public struct KernovaLogger: Sendable {

    public let subsystem: String
    public let category: String
    private let osLogger: Logger

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.osLogger = Logger(subsystem: subsystem, category: category)
    }

    // MARK: - Levels

    public func debug(_ message: KernovaLogMessage) {
        osLogger.debug("\(message.localRendered, privacy: .public)")
        forward(level: .debug, message: message.wireRendered)
    }

    public func info(_ message: KernovaLogMessage) {
        osLogger.info("\(message.localRendered, privacy: .public)")
        forward(level: .info, message: message.wireRendered)
    }

    public func notice(_ message: KernovaLogMessage) {
        osLogger.notice("\(message.localRendered, privacy: .public)")
        forward(level: .notice, message: message.wireRendered)
    }

    public func warning(_ message: KernovaLogMessage) {
        osLogger.warning("\(message.localRendered, privacy: .public)")
        forward(level: .warning, message: message.wireRendered)
    }

    public func error(_ message: KernovaLogMessage) {
        osLogger.error("\(message.localRendered, privacy: .public)")
        forward(level: .error, message: message.wireRendered)
    }

    public func fault(_ message: KernovaLogMessage) {
        osLogger.fault("\(message.localRendered, privacy: .public)")
        forward(level: .fault, message: message.wireRendered)
    }

    // MARK: - Forwarding

    private func forward(
        level: Kernova_V1_LogRecord.Level,
        message: String
    ) {
        VsockLogBridge.connection?.forwardLog(
            level: level,
            subsystem: subsystem,
            category: category,
            message: message
        )
    }
}
