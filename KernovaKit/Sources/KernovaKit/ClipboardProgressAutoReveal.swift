import Foundation

/// What became of one readout update's chance at the automatic reveal.
public enum ClipboardProgressRevealDecision: Equatable, Sendable {
    /// No reveal was asked for.
    case none
    /// The readout's callout went up.
    case shown
    /// The readout earned its reveal, but the status item could not carry the
    /// callout; the reveal stays unspent.
    case notShown
}

/// Decides when a transfer's progress readout reveals itself in the status
/// item's callout, without the user opening the dropdown.
///
/// The callout is the only progress surface that shows unsummoned, so it
/// reveals at most once per operation and only for a gesture someone is waiting
/// on — a peer's paste, which holds the app it is pasting into, and a drop or a
/// drag out, whose files are not where the user put them until it lands. It
/// waits until the transfer has run for `minimumElapsedToReveal` with at least
/// `minimumRemainingToReveal` still to go.
///
/// Spending is keyed on the readout's operation, never on gaps in the report:
/// once an operation's reveal is spent, neither it nor any operation started
/// before it reveals again, so a readout that clears and returns — a
/// concurrent refusal publishing in between — or a surface that goes back to an
/// older operation never re-raises a callout the user already had.
public struct ClipboardProgressAutoReveal: Equatable, Sendable {
    /// How long a transfer must have been running before it may reveal itself.
    public static let defaultMinimumElapsedToReveal: TimeInterval = 1

    /// How much work a transfer must still have left before it may reveal
    /// itself.
    public static let defaultMinimumRemainingToReveal: TimeInterval = 1

    private let minimumElapsedToReveal: TimeInterval
    private let minimumRemainingToReveal: TimeInterval

    /// The latest-started operation whose reveal is spent.
    private var lastSpent: ClipboardTransferOperationID?

    /// Creates a decider with nothing in flight.
    public init(
        minimumElapsedToReveal: TimeInterval =
            ClipboardProgressAutoReveal.defaultMinimumElapsedToReveal,
        minimumRemainingToReveal: TimeInterval =
            ClipboardProgressAutoReveal.defaultMinimumRemainingToReveal
    ) {
        self.minimumElapsedToReveal = minimumElapsedToReveal
        self.minimumRemainingToReveal = minimumRemainingToReveal
    }

    /// Folds in a change to the delivered readout, calling `reveal` when this
    /// readout earns its operation's one reveal.
    ///
    /// `readout` is the snapshot being shown (`nil` when the readout clears) and
    /// `dropdownIsOpen` whether the dropdown, which carries the readout itself,
    /// is on screen. `reveal` shows the callout and returns whether it went up:
    /// a status item that can't carry it — dropped from a crowded menu bar, or
    /// behind a full-screen window — showed nothing, so the reveal is not spent
    /// and a later update can still take it.
    public mutating func readoutChanged(
        _ readout: ClipboardProgressSnapshot?, dropdownIsOpen: Bool, reveal: () -> Bool
    ) -> ClipboardProgressRevealDecision {
        guard let readout else { return .none }
        if let lastSpent, readout.operationID <= lastSpent { return .none }
        // Must stay ahead of the `dropdownIsOpen` branch: a readout nobody is
        // waiting on must not spend the reveal, or a preview fetch overlapping a
        // paste would answer the paste's one chance with a dropdown the user
        // never saw.
        guard readout.gesture.isAwaited else { return .none }
        if dropdownIsOpen {
            // The readout goes straight into the open dropdown, so the operation
            // has had its showing — spending the reveal here is what stops the
            // next update from raising a callout once the user dismisses it.
            lastSpent = readout.operationID
            return .none
        }
        guard isWorthRevealing(readout) else { return .none }
        guard reveal() else { return .notShown }
        lastSpent = readout.operationID
        return .shown
    }

    /// Whether the transfer has been running long enough, and has enough left to
    /// run, to be worth showing unsummoned.
    private func isWorthRevealing(_ readout: ClipboardProgressSnapshot) -> Bool {
        guard readout.elapsedSeconds >= minimumElapsedToReveal else { return false }
        // Without a total there is no estimate to weigh, so the elapsed floor is
        // the whole test.
        guard readout.totalBytes > 0, !readout.awaitsSize else { return true }
        // Every byte is in and only the terminal is outstanding. Checked before
        // consulting the estimate because `secondsRemaining` reports `nil` both
        // here and before a rate exists, and those two mean opposite things.
        guard readout.bytesTransferred < readout.totalBytes else { return false }
        // Running this long with no measurable rate means stalled or slow, not
        // about to finish.
        guard let remaining = readout.secondsRemaining else { return true }
        return remaining >= minimumRemainingToReveal
    }
}
