import Foundation

/// The user action a transfer serves, from the reporting side's point of view.
public enum ClipboardTransferGesture: Equatable, Sendable {
    /// This side's user pasted the peer's offer — a pasteboard promise firing and
    /// pulling the bytes it advertised.
    case paste
    /// The peer's user pasted and this side serves the pull. The app pasted into
    /// sits blocked until the bytes land.
    case peerPaste
    /// This side's clipboard window is filling in a preview of the peer's offer.
    case preview
    /// Copy to Mac — the click, or the automatic passthrough publish of a guest
    /// offer.
    case copy
    /// Automatic passthrough forwarded this side's copy to the peer.
    case forward
    /// Files dropped on the VM display — the host sends, the guest receives.
    case drop

    /// Whether the user owed the message is on this side.
    ///
    /// docs/CLIPBOARD.md §13 — report a refusal on the side that made the
    /// gesture. Everything but `peerPaste`, which refuses the *peer* user's
    /// paste and is theirs to be told about.
    public var isMadeHere: Bool { self != .peerPaste }

    /// Whether someone is waiting in front of a screen for this gesture to end,
    /// which is what earns its readout the surfaces that interrupt
    /// (docs/CLIPBOARD.md §13).
    ///
    /// A peer's paste holds the app it is pasting into; a drop leaves the files
    /// out of the guest until it lands. The rest run behind whatever the user is
    /// doing.
    public var isAwaited: Bool { self == .peerPaste || self == .drop }

    /// Which of several concurrent readouts a single-value surface shows —
    /// higher wins, ties settled by which opened its bar last.
    ///
    /// A paste that blocks an app outranks work the user can walk away from, so
    /// a drop started mid-paste never takes the bar off the transfer someone is
    /// sitting in front of.
    public var readoutRank: Int { self == .peerPaste ? 1 : 0 }
}

/// Why a clipboard or drop transfer did not deliver what the gesture asked for.
///
/// One case per distinct sentence a surface must be able to write; the gesture it
/// is paired with supplies the rest of the wording.
public enum ClipboardTransferFailure: Equatable, Sendable {
    /// This side's staging volume has no room. `needed` is the transfer size,
    /// `nil` when the payload declared none; `available` is the free capacity
    /// when it could be read.
    case diskFull(needed: UInt64?, available: Int64?)
    /// Over the transfer ceiling in force when the refusal was raised — the copy
    /// budget under `.copy`, the peer's paste cap under `.peerPaste`.
    case tooLarge(limitBytes: Int)
    /// The peer reported a failure of its own; `nil` for a code this build does
    /// not define.
    case peerReported(ClipboardErrorCode?)
    /// A Copy to Mac still on the host pasteboard was retracted because the guest
    /// clipboard moved on. `hasSuccessor` is whether a guest offer took its
    /// place, so the message can point at Copy to Mac.
    case supersededCopyRetracted(hasSuccessor: Bool)
    /// A paste fired after the session ended with only part of the copied file
    /// set staged, so nothing was served rather than a silent subset.
    case incompleteFileSet
    /// The session ended mid-transfer. `fileCount` is how many files a drop was
    /// still carrying; `nil` for a paste, which speaks of the clipboard.
    case interrupted(fileCount: Int?)
    /// The receiver gave up waiting for bytes that stopped arriving.
    case timedOut
    /// The transfer aborted for a reason with no more specific case.
    case transferFailed
    /// The bytes arrived but could not be unpacked into the file or folder.
    case unpackFailed
    /// The bytes arrived but could not be written to a file on this side.
    case stagingFailed
    /// Items this side could not read were left out of what it sent, and the
    /// rest crossed; `note` is the sentence the raising side words it in.
    case itemsSkipped(note: String)
    /// None of the dropped items could be read, so nothing was sent.
    case itemsUnreadable
    /// The drop offer itself could not be sent.
    case sendFailed
    /// The peer never asked for a single item of an offered drop, so the batch
    /// was called off rather than left waiting forever.
    case unclaimed
}

extension ClipboardTransferFailure {
    /// The refusal a drop raises for `count` items it could not send, whether
    /// they were left out of the offer or failed to be read once the guest
    /// asked for them.
    public static func itemsSkipped(count: Int) -> ClipboardTransferFailure {
        .itemsSkipped(
            note: count == 1
                ? "One item couldn\u{2019}t be read, so it wasn\u{2019}t sent to the VM. The rest were."
                : "\(count) items couldn\u{2019}t be read, so they weren\u{2019}t sent to the VM. The rest were."
        )
    }

    /// The failure a `diskFull` abort carries, from whatever numbers it knew.
    public static func diskFull(from info: ClipboardStreamAbortInfo) -> ClipboardTransferFailure {
        .diskFull(
            needed: info.neededBytes.map(UInt64.init(clamping:)),
            available: info.availableBytes.map(Int64.init(clamping:)))
    }

    /// What an aborted inbound pull reports — one classification for every pull
    /// of a peer offer, the paste-time blocking fire and the lazy preview pull
    /// alike — or `nil` when the abort retires the transfer quietly.
    ///
    /// A code this build does not define is a failure to surface, not one to
    /// swallow: `isRetiring` is false for it, so it lands on the generic failure
    /// alongside every read, integrity, staging, and timeout code.
    public static func inboundPullAborted(
        _ info: ClipboardStreamAbortInfo
    ) -> ClipboardTransferFailure? {
        guard !info.isRetiring else { return nil }
        switch info.code {
        case .diskFull: return .diskFull(from: info)
        case .extractError: return .unpackFailed
        default: return .transferFailed
        }
    }
}

/// How a clipboard operation ended.
public enum ClipboardTransferOutcome: Equatable, Sendable {
    /// Ran to its end; `final` is the last readout, so a surface can dwell on the
    /// bar at 100 %.
    case completed(final: ClipboardProgressSnapshot)
    /// Stopped by the user; `final` is where the bar stopped, below 100 % by
    /// design.
    case cancelled(final: ClipboardProgressSnapshot)
    /// Did not deliver what the gesture asked for.
    case failed(ClipboardTransferFailure)
}

/// One finished clipboard operation, with everything a surface needs to write
/// the sentence for it.
public struct ClipboardTransferFinish: Equatable, Sendable {
    /// The user action the operation served.
    public let gesture: ClipboardTransferGesture
    /// How it ended.
    public let outcome: ClipboardTransferOutcome
    /// Display name of the machine on the other end.
    public let peerName: String
    /// Re-fire identity: two finishes of the same kind from separate events
    /// compare unequal, so a surface can re-show a message it already dismissed.
    public let date: Date

    /// Records one operation's terminal.
    public init(
        gesture: ClipboardTransferGesture, outcome: ClipboardTransferOutcome, peerName: String,
        date: Date = Date()
    ) {
        self.gesture = gesture
        self.outcome = outcome
        self.peerName = peerName
        self.date = date
    }

    /// The failure this finish carries, or `nil` when it did not fail.
    public var failure: ClipboardTransferFailure? {
        guard case .failed(let failure) = outcome else { return nil }
        return failure
    }

    /// The last readout of an operation that ran, or `nil` for one that failed
    /// without one.
    public var finalSnapshot: ClipboardProgressSnapshot? {
        switch outcome {
        case .completed(let final), .cancelled(let final): return final
        case .failed: return nil
        }
    }

    /// Whether two finishes describe the same news, ignoring when it happened.
    ///
    /// The N pasteboard fires of one refused multi-file paste each report the
    /// same refusal; this is what lets them collapse into one.
    public func isSameNews(as other: ClipboardTransferFinish) -> Bool {
        gesture == other.gesture && outcome == other.outcome && peerName == other.peerName
    }
}

/// One side's clipboard transfer state for one peer — the single value every
/// progress and refusal surface renders.
public enum ClipboardTransferReport: Equatable, Sendable {
    /// Nothing to show.
    case idle
    /// An operation is on screen, past its reveal gate. `since` is when it
    /// started, so an app-level surface can rank one peer's readout against
    /// another's.
    case running(ClipboardProgressSnapshot, since: Date)
    /// The last operation to end still stands.
    case finished(ClipboardTransferFinish)
}
