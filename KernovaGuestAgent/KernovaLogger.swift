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
struct KernovaLogger: Sendable {
    let subsystem: String
    let category: String
    private let osLogger: Logger

    init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.osLogger = Logger(subsystem: subsystem, category: category)
    }

    // MARK: - Levels

    func debug(_ message: KernovaLogMessage) {
        osLogger.debug("\(message.localRendered, privacy: .public)")
        forward(level: .debug, message: message.wireRendered)
    }

    // periphery:ignore - Preserves a complete `os.Logger`-shaped surface
    // (debug / info / notice / warning / error / fault). No agent code
    // currently calls `.info`, but keeping the level lets new call sites
    // pick the right severity without asymmetric workarounds.
    func info(_ message: KernovaLogMessage) {
        osLogger.info("\(message.localRendered, privacy: .public)")
        forward(level: .info, message: message.wireRendered)
    }

    func notice(_ message: KernovaLogMessage) {
        osLogger.notice("\(message.localRendered, privacy: .public)")
        forward(level: .notice, message: message.wireRendered)
    }

    func warning(_ message: KernovaLogMessage) {
        osLogger.warning("\(message.localRendered, privacy: .public)")
        forward(level: .warning, message: message.wireRendered)
    }

    func error(_ message: KernovaLogMessage) {
        osLogger.error("\(message.localRendered, privacy: .public)")
        forward(level: .error, message: message.wireRendered)
    }

    func fault(_ message: KernovaLogMessage) {
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
