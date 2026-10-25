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

    /// The paste's bytes arrived but the receiving side could not unpack them;
    /// the frame carries the entry it could not write when it named one.
    case pasteUnpackFailed = "clipboard.paste.unpack.failed"

    /// The offer's paste-bound reps exceed the deadline-safe cap, so the host
    /// refused the Copy-to-Mac gesture.
    ///
    /// Never crosses the wire: the host both refuses and reports this one, so it
    /// names the refusal in the log and in the host's own transfer issue rather
    /// than in a frame.
    case copyTooLarge = "clipboard.copy.too.large"

    /// The paste fired after the VM session ended with only part of the copied
    /// file set materialized, so the host refused to serve an incomplete set.
    ///
    /// Never crosses the wire: like `copyTooLarge`, the host both refuses and
    /// reports it.
    case pasteIncompleteSet = "clipboard.paste.incomplete.set"

    /// The host could not read every copied item, so the offer forwarded to the
    /// guest left some out.
    ///
    /// Never crosses the wire: like `copyTooLarge`, the host both skips and
    /// reports it.
    case forwardItemsSkipped = "clipboard.forward.items.skipped"

    /// The guest has no room to write a dropped file into its Downloads folder.
    case dropDiskFull = "clipboard.drop.disk.full"

    /// The guest could not write into its Downloads folder — the guest user has
    /// not granted the agent access to it.
    case dropDownloadsDenied = "clipboard.drop.downloads.denied"

    /// A dropped file did not reach the guest's Downloads folder, for a reason
    /// with no more specific code.
    case dropFailed = "clipboard.drop.failed"

    /// A dropped item's bytes arrived but the guest could not unpack them; the
    /// `DropComplete` carries the entry it could not write when it named one.
    case dropUnpackFailed = "clipboard.drop.unpack.failed"

    /// The guest could not hand a drag over because the take named a drag that
    /// is not its current one, or the press that carried it is over.
    case dragTakeStale = "clipboard.drag.take.stale"

    /// The guest's drag manager brought the catcher something other than the
    /// taken drag, or a drag that does not allow a copy.
    case dragTakeRefused = "clipboard.drag.take.refused"

    /// The guest could not hand a drag over, for a reason with no more specific
    /// code.
    case dragTakeFailed = "clipboard.drag.take.failed"

    /// A promised item of a guest drag will never have bytes to pull: its
    /// source failed to write it.
    ///
    /// Never crosses the wire: the guest says so in `DragSizes.unavailable`,
    /// and the host both refuses the pull (``LazyPullOutcome/unavailable``) and
    /// reports it.
    case dragItemUnavailable = "clipboard.drag.item.unavailable"
}
