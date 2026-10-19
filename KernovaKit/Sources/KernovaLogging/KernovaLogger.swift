import KernovaSynchronization
import os

/// Emits each message to the unified log under its subsystem and category,
/// and to the forwarding sink when there is one.
public struct KernovaLogger: Sendable {
    /// The `os.Logger` subsystem, also tagged on each forwarded record.
    public let subsystem: String

    /// The `os.Logger` category, also tagged on each forwarded record.
    public let category: String

    private let osLog: OSLog
    private let osLogger: os.Logger

    /// This logger's own sink, which `forwardingSink` prefers over the
    /// `processSink`.
    public let sink: ForwardingSink?

    /// Creates a logger for a subsystem and category with `sink` as its own
    /// sink — how a test captures what the component it builds logs.
    public init(subsystem: String, category: String, sink: ForwardingSink? = nil) {
        self.subsystem = subsystem
        self.category = category
        self.osLog = OSLog(subsystem: subsystem, category: category)
        self.osLogger = os.Logger(osLog)
        self.sink = sink
    }

    /// Logs `message` at `level`.
    ///
    /// `message` is built only when the unified log records `level` for this
    /// logger or a forwarding sink exists; otherwise it is never evaluated.
    public func log(_ level: KernovaLogLevel, _ message: @autoclosure () -> LogMessage) {
        let sink = forwardingSink
        let type = level.osLogType
        let isEnabled = osLog.isEnabled(type: type)
        guard isEnabled || sink != nil else { return }
        let segments = message().segments
        if isEnabled {
            LocalLogRecord(segments: segments).emit(to: osLogger, at: type)
        }
        sink?(level, subsystem, category, segments)
    }

    // MARK: - Forwarding sink

    /// Receives every emission for forwarding to a remote destination:
    /// `(level, subsystem, category, message segments)`.
    public typealias ForwardingSink =
        @Sendable (
            _ level: KernovaLogLevel,
            _ subsystem: String,
            _ category: String,
            _ segments: [LogSegment]
        ) -> Void

    /// Where `log(_:_:)` forwards this logger's records: its own `sink`, or
    /// else the `processSink`; `nil` when there is neither.
    var forwardingSink: ForwardingSink? {
        sink ?? Self.processSink
    }

    private static let processSinkStorage = Locked<ForwardingSink?>(nil)

    /// The sink every logger without its own forwards to: what
    /// `bootstrapProcessSink(_:)` installed, or `nil` before that and in any
    /// process that never calls it.
    public static var processSink: ForwardingSink? {
        processSinkStorage.withLock { $0 }
    }

    /// Installs the process's one `processSink`.
    ///
    /// Traps when called a second time. A test never calls it: it captures
    /// through a logger built with its own `sink`, injected into the component
    /// under test.
    public static func bootstrapProcessSink(_ sink: @escaping ForwardingSink) {
        processSinkStorage.withLock { installed in
            precondition(installed == nil, "KernovaLogger.bootstrapProcessSink called more than once")
            installed = sink
        }
    }
}
