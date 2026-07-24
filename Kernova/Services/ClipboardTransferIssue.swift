import Foundation

/// A user-visible clipboard transfer problem, surfaced by `ClipboardServicing`
/// implementations for the clipboard window to display.
///
/// `date` doubles as the re-fire identity: two issues of the same kind from
/// separate failures compare unequal, so the window can re-show a transient
/// message it has already dismissed once.
struct ClipboardTransferIssue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Not enough disk space on the receiving side to stage a streamed file.
        /// `needed` is the transfer size; `available` is the staging volume's
        /// free capacity when known.
        case diskFull(needed: Int, available: Int?)

        /// The peer rejected a clipboard message (e.g. format unavailable,
        /// delivery failure on its side).
        case peerReportedError(code: String, message: String)
    }

    let kind: Kind
    let date: Date
}
