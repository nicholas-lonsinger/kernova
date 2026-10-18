import Foundation
import KernovaSynchronization

// A `#log` expansion calls `os` members at its call site, so a module built
// with MemberImportVisibility resolves them only if `os` comes in with this one.
@_exported import os

/// An `os.Logger` plus the labels a forwarded copy of each message carries.
///
/// The `#log` macro is the only way to emit through one: it hands the message
/// literal straight to `osLogger`, so `logd`-side laziness, per-value privacy
/// and `format:`/`align:` all behave exactly as they do at a bare `os.Logger`
/// call site, and renders the interpolations a second time only when there is
/// a sink to forward to — the logger's own `sink`, or else the `processSink`.
public struct KernovaLogger: Sendable {
    /// The `os.Logger` subsystem, also tagged on each forwarded record.
    public let subsystem: String

    /// The `os.Logger` category, also tagged on each forwarded record.
    public let category: String

    /// The logger the local emission goes to. Called by the `#log` expansion
    /// and nothing else — a direct call would bypass the forwarding sink.
    public let osLogger: os.Logger

    /// Where this logger forwards in place of the `processSink`, or `nil` to
    /// forward to the `processSink`.
    public let sink: ForwardingSink?

    /// Creates a logger for a subsystem and category, forwarding to `sink`
    /// when one is given — how a test captures what the component it builds
    /// logs — and to the `processSink` otherwise.
    public init(subsystem: String, category: String, sink: ForwardingSink? = nil) {
        self.subsystem = subsystem
        self.category = category
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
        self.sink = sink
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

/// Logs `message` through `logger` at `level`.
///
/// `message` must be written as a string literal. Its interpolations take the
/// same `privacy:`, `format:` and `align:` arguments an `os.Logger` call takes,
/// and the literal reaches `os.Logger` untouched. A forwarded copy carries the
/// same message split into `LogSegment`s, each interpolation marked private or
/// public by its `privacy:` argument — or, with none, by whether `os.Logger`
/// would redact that value's type by default.
///
/// - Parameters:
///   - logger: the logger to emit through.
///   - level: the level to emit at; any `KernovaLogLevel` expression.
///   - message: the message, written literally at the call site.
@freestanding(expression)
public macro log(_ logger: KernovaLogger, _ level: KernovaLogLevel, _ message: OSLogMessage) =
    #externalMacro(module: "KernovaLoggingMacros", type: "LogMacro")
