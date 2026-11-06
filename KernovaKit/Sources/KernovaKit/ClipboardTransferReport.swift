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
    /// The guest's clipboard written to the Mac's — Copy Guest Clipboard to Mac,
    /// or the automatic passthrough publish of a guest offer.
    case copy
    /// Copy Mac Clipboard to Guest.
    case send
    /// Automatic passthrough forwarded this side's copy to the peer.
    case forward
    /// Files dropped on the VM display — the host sends, the guest receives.
    case drop
    /// Files dragged out of the VM display onto the Mac — the guest sends, the
    /// host receives.
    case dragOut

    /// Whether the user owed the message is on this side.
    ///
    /// A refusal is reported on the side that made the gesture, so this is
    /// everything but `peerPaste`, which refuses the *peer* user's paste and is
    /// theirs to be told about.
    public var isMadeHere: Bool { self != .peerPaste }

    /// Whether someone is waiting in front of a screen for this gesture to end,
    /// which is what earns its readout the callout that shows by itself.
    ///
    /// A peer's paste holds the app it is pasting into; a drop or a drag out
    /// leaves the files missing where the user put them until it lands. The rest
    /// run behind whatever the user is doing.
    public var isAwaited: Bool { self == .peerPaste || self == .drop || self == .dragOut }

    /// Which of several concurrent readouts a single-value surface shows —
    /// higher wins, ties settled by which opened its bar last.
    ///
    /// The order ``isAwaited`` implies, with the paste that holds an app ahead
    /// of the drop or drag whose files have not landed yet: a drop started
    /// mid-paste never takes the bar off the transfer someone is sitting in
    /// front of, and a preview fetch never takes it off either.
    public var readoutRank: Int {
        switch self {
        case .peerPaste: 2
        case .drop, .dragOut: 1
        case .paste, .preview, .copy, .forward, .send: 0
        }
    }
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
    /// The peer reported a failure of its own.
    case peerReported(ClipboardErrorCode)
    /// A Copy to Mac still on the host pasteboard was retracted whole because the guest's connection ended, so
    /// nothing more of it could be pasted.
    case disconnectedCopyRetracted
    /// The files of a copy still on the host pasteboard were retracted, each with the item holding it, because
    /// the guest's connection ended; the rest of the copy stays.
    case disconnectedFilesRetracted
    /// A Copy to Mac still on the host pasteboard was retracted whole because the guest withdrew it, its
    /// connection still up.
    case withdrawnCopyRetracted
    /// The files of a copy still on the host pasteboard were retracted, each with the item holding it, because
    /// the guest withdrew the copy, its connection still up; the rest of the copy stays.
    case withdrawnFilesRetracted
    /// The session ended mid-transfer. `fileCount` is how many files a drop was
    /// still carrying; `nil` for a paste, which speaks of the clipboard.
    case interrupted(fileCount: Int?)
    /// One side gave up waiting on the other — bytes that stopped arriving, or a
    /// peer that stopped taking the ones it had begun.
    case timedOut
    /// The transfer aborted for a reason with no more specific case.
    case transferFailed
    /// The sending side could not read what it was sending, so the transfer
    /// stopped there.
    case sourceUnreadable
    /// The bytes arrived but could not be written to a file on this side.
    case stagingFailed
    /// Items the sending side did not send whole, and the rest crossed whole;
    /// `count` is how many. A gesture that reads a pasteboard leaves out a file
    /// it cannot read or that is gone, the rest of its item crossing; a
    /// snapshot also leaves out what it could not read or pull from another
    /// offer. A drop's items are its files.
    case itemsSkipped(count: Int)
    /// None of the gesture's items could be read, so nothing was sent.
    case itemsUnreadable
    /// The drop offer itself could not be sent.
    case sendFailed
    /// This side ended a drop the VM had not finished landing, for the reason given.
    case dropStopped(ClipboardDropStop)
    /// The destination's clipboard changed before a copy to it landed, so it was
    /// left as it is.
    case clipboardChanged
    /// The source's clipboard held nothing a copy could carry.
    case nothingToCopy
    /// A copy was written without its `count` files, which together are over the transfer ceiling `limitBytes`.
    case filesLeftOut(count: Int, limitBytes: Int)
    /// A copy named what the destination had sent, and the destination no longer had some of it, so it was
    /// left out.
    case partsGone
    /// The source's clipboard held no text, the one thing a text-only transport
    /// carries.
    case noTextToCopy
}

/// Why this side ended a drop the VM had not finished landing, as this side observed it.
public enum ClipboardDropStop: Equatable, Sendable {
    /// The VM's settings had file drops off.
    case turnedOff
    /// No guest agent in the VM was taking drops.
    case noAgent
    /// Another guest agent in the VM took the VM's drops over.
    case movedToAnotherAgent
}

extension ClipboardTransferFailure {
    /// Whether the rest of what the gesture carried reached its destination and stays there: only this part is
    /// missing.
    public var deliveredTheRest: Bool {
        switch self {
        case .itemsSkipped, .filesLeftOut, .partsGone, .disconnectedFilesRetracted, .withdrawnFilesRetracted: true
        default: false
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

    /// What the log records of a finish that did not deliver everything, partial or failed; nil for one that
    /// did.
    var logLine: String? {
        guard let failure else { return nil }
        let ending = failure.deliveredTheRest ? "was partial" : "failed"
        return "\(gesture) from '\(peerName)' \(ending): \(failure)"
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
