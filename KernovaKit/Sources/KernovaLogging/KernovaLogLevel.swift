import os

/// The level a `#log` emission carries, locally and on the wire.
public enum KernovaLogLevel: Sendable {
    /// Method entry and intermediate state.
    case debug
    /// Routine progress.
    case info
    /// State transitions and irreversible actions.
    case notice
    /// Recoverable trouble.
    case warning
    /// An operation that did not complete.
    case error
    /// A programming error.
    case fault

    /// The `OSLogType` `os.Logger`'s same-named method would log at.
    ///
    /// `.warning` and `.error` share `OSLogType.error`, as they do in
    /// `os.Logger`; the distinction survives on the forwarded record.
    public var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning, .error: .error
        case .fault: .fault
        }
    }
}
