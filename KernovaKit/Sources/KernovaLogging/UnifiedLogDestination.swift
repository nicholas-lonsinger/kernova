#if canImport(os)
import os

/// Where a `KernovaLogger` records locally on Apple platforms: the unified
/// log, under the logger's subsystem and category.
struct UnifiedLogDestination: Sendable {
    private let osLog: OSLog
    private let osLogger: os.Logger

    init(subsystem: String, category: String) {
        osLog = OSLog(subsystem: subsystem, category: category)
        osLogger = os.Logger(osLog)
    }

    /// Whether the unified log records `level` for this subsystem and
    /// category right now.
    func records(_ level: KernovaLogLevel) -> Bool {
        osLog.isEnabled(type: level.osLogType)
    }

    func emit(_ segments: [LogSegment], at level: KernovaLogLevel) {
        LocalLogRecord(segments: segments).emit(to: osLogger, at: level.osLogType)
    }
}
#endif

/// Where a `KernovaLogger` records locally on this platform.
#if canImport(os)
typealias LocalLogDestination = UnifiedLogDestination
#else
typealias LocalLogDestination = StandardErrorLogDestination
#endif
