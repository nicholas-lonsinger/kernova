import Foundation

/// What the status-item controller should do with its dropdown in response to a
/// change in the clipboard progress readout.
public enum ClipboardProgressMenuAction: Equatable, Sendable {
    case none
    /// Pop the dropdown open so the readout is visible without a click.
    case open
    /// Dismiss the dropdown this opener opened.
    case close
}

/// Decides when a transfer's progress readout opens and closes the status-item
/// dropdown on its own.
///
/// This is the only progress surface that interrupts, so it opens at most once
/// per operation and only for a gesture someone is waiting on — a peer's paste,
/// which holds the app it is pasting into, and a drop, whose files are not in
/// the guest until it lands (docs/CLIPBOARD.md §13). It waits until the transfer
/// has run for `minimumElapsedToOpen` with at least `minimumRemainingToOpen`
/// still to go, and it closes only a dropdown it opened itself.
public struct ClipboardProgressMenuAutoOpener: Equatable, Sendable {
    /// How long a transfer must have been running before it may interrupt.
    public static let defaultMinimumElapsedToOpen: TimeInterval = 2

    /// How much work a transfer must still have left before it may interrupt.
    public static let defaultMinimumRemainingToOpen: TimeInterval = 2

    private let minimumElapsedToOpen: TimeInterval
    private let minimumRemainingToOpen: TimeInterval

    /// Whether a readout is currently showing.
    private var readoutActive = false
    /// Whether the operation on screen has already had its one automatic open.
    private var openedThisOperation = false
    /// Whether the dropdown currently on screen is the one this opener popped.
    private var openedByThisOpener = false

    /// Creates an opener with nothing in flight.
    public init(
        minimumElapsedToOpen: TimeInterval =
            ClipboardProgressMenuAutoOpener.defaultMinimumElapsedToOpen,
        minimumRemainingToOpen: TimeInterval =
            ClipboardProgressMenuAutoOpener.defaultMinimumRemainingToOpen
    ) {
        self.minimumElapsedToOpen = minimumElapsedToOpen
        self.minimumRemainingToOpen = minimumRemainingToOpen
    }

    /// Folds in a change to the delivered readout.
    ///
    /// `readout` is the snapshot being shown (`nil` when the readout clears),
    /// `menuIsOpen` whether the dropdown is on screen, and `canOpen` `false` when
    /// the status item itself is not — dropped from a crowded menu bar, or behind
    /// a full-screen window — where a popped dropdown would appear detached from
    /// anything.
    public mutating func readoutChanged(
        _ readout: ClipboardProgressSnapshot?, menuIsOpen: Bool, canOpen: Bool
    ) -> ClipboardProgressMenuAction {
        guard let readout else {
            defer {
                readoutActive = false
                openedThisOperation = false
                openedByThisOpener = false
            }
            guard readoutActive, menuIsOpen, openedByThisOpener else { return .none }
            return .close
        }
        // A readout arriving while none was showing starts a new operation.
        if !readoutActive {
            readoutActive = true
            openedThisOperation = false
        }
        guard !openedThisOperation else { return .none }
        // Must stay ahead of the `menuIsOpen` branch: a readout nobody is waiting
        // on must not spend the open, or a preview fetch overlapping a paste would
        // answer the paste's one chance with a dropdown the user never saw.
        guard readout.gesture.isAwaited else { return .none }
        if menuIsOpen {
            // The readout goes straight into the already-open dropdown, so the
            // operation has had its showing — spending the open here is what stops
            // the next update from re-popping a dropdown the user just dismissed.
            openedThisOperation = true
            return .none
        }
        // A hidden status item showed nothing, so the open is not spent and a
        // later update can still take it.
        guard canOpen else { return .none }
        guard isWorthInterrupting(readout) else { return .none }
        openedThisOperation = true
        return .open
    }

    /// Records that the dropdown opened, and whether this opener asked for it.
    public mutating func menuOpened(automatically: Bool) {
        openedByThisOpener = automatically
    }

    /// Records that the dropdown closed, for whatever reason.
    ///
    /// A user dismissal lands here too; `openedThisOperation` stays set for the
    /// rest of the operation, so the dropdown never re-opens over them.
    public mutating func menuClosed() {
        openedByThisOpener = false
    }

    /// Whether the transfer has been running long enough, and has enough left to
    /// run, to be worth taking over the screen for.
    private func isWorthInterrupting(_ readout: ClipboardProgressSnapshot) -> Bool {
        guard readout.elapsedSeconds >= minimumElapsedToOpen else { return false }
        // Without a total there is no estimate to weigh, so the elapsed floor is
        // the whole test.
        guard readout.totalBytes > 0 else { return true }
        // Every byte is in and only the terminal is outstanding. Checked before
        // consulting the estimate because `secondsRemaining` reports `nil` both
        // here and before a rate exists, and those two mean opposite things.
        guard readout.bytesTransferred < readout.totalBytes else { return false }
        // Running this long with no measurable rate means stalled or slow, not
        // about to finish.
        guard let remaining = readout.secondsRemaining else { return true }
        return remaining >= minimumRemainingToOpen
    }
}
