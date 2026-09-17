import Foundation
import os

/// An `os.Logger` plus the labels a forwarded copy of each message carries.
///
/// The `#log` macro is the only way to emit through one: it hands the message
/// literal straight to `osLogger`, so `logd`-side laziness, per-value privacy
/// and `format:`/`align:` all behave exactly as they do at a bare `os.Logger`
/// call site, and renders the interpolations a second time only when a
/// `forwardingSink` is installed.
public struct KernovaLogger: Sendable {
    /// The `os.Logger` subsystem, also tagged on each forwarded record.
    public let subsystem: String

    /// The `os.Logger` category, also tagged on each forwarded record.
    public let category: String

    /// The logger the local emission goes to. Called by the `#log` expansion
    /// and nothing else — a direct call would bypass the forwarding sink.
    public let osLogger: os.Logger

    /// Creates a logger for a subsystem and category.
    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
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

    // `nonisolated(unsafe)`: assign this once during synchronous startup, before
    // any background `Task` can fire a log line, and treat it as read-only
    // thereafter — nothing here guards a concurrent write.
    /// Process-wide forwarding sink the guest agent installs to relay each
    /// emission to the host over vsock; the host app leaves it `nil`.
    nonisolated(unsafe) public static var forwardingSink: ForwardingSink?
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
