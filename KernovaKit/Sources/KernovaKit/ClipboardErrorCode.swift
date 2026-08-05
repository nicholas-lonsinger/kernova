import Foundation

/// Stable machine-readable codes for a clipboard failure, named
/// `clipboard.<gesture>.<condition>`.
///
/// The raw value is what an `Error` frame carries and what the host's clipboard
/// window maps to a message, so producer and renderer share one spelling.
public enum ClipboardErrorCode: String, CaseIterable, Sendable {
    /// The offer's paste-bound reps exceed the deadline-safe cap, so the guest
    /// refused the paste pull.
    case pasteTooLarge = "clipboard.paste.too.large"

    /// The receiving side has no room to stage the streamed file.
    case pasteDiskFull = "clipboard.paste.disk.full"

    /// The receiver gave up waiting for the transfer.
    case pasteTimeout = "clipboard.paste.timeout"

    /// The paste failed for a reason with no more specific code.
    case pasteFailed = "clipboard.paste.failed"

    /// The offer's paste-bound reps exceed the deadline-safe cap, so the host
    /// refused the Copy-to-Mac gesture.
    ///
    /// The one code that never crosses the wire: the host both refuses and
    /// reports this one, so it names the refusal in the log and in the host's own
    /// transfer issue rather than in a frame.
    case copyTooLarge = "clipboard.copy.too.large"
}
