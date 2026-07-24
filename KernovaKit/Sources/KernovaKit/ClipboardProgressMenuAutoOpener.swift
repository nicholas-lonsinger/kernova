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
/// dropdown on its own (#643, #652).
///
/// Pure state, so both status-item controllers share one set of rules and those
/// rules are testable without a menu bar. Every other progress surface is
/// passive — a bar, or a ring drawn on an icon already in the menu bar — and so
/// appears as soon as the tracker reveals anything. This one *interrupts*, taking
/// over the screen uninvited, so it is the only surface with a bar to clear, and
/// the rules exist to make that interruption respectful:
///
/// - **Only a paste.** A File Provider paste is the one operation with no surface
///   of its own: the user pressed ⌘V in Finder, and the window that would show a
///   bar belongs to Finder, not us. Every other flow starts in the clipboard
///   window, which is already showing this same readout, so popping a dropdown
///   over it would be pure noise.
/// - **Only if it will still be running.** A transfer that will be over in a
///   moment would put the dropdown on screen to answer a question the user no
///   longer has by the time they read it. It must have been running for
///   `minimumElapsedToOpen` *and* have at least `minimumRemainingToOpen` of work
///   left. Failing this does **not** spend the paste's one open — an operation
///   that turns out slower than its early estimate can still earn it later.
/// - **Once per paste.** The dropdown opens when a paste's readout first appears,
///   and never again for that paste. A user who closes it has said no, and
///   re-opening over their next click would be the behavior everyone hates.
/// - **Only what it opened, it closes.** When the paste ends, a dropdown this
///   opener popped is dismissed; one the user opened themselves is left exactly
///   where they put it.
/// - **Never on top of an open menu.** If the dropdown is already showing when the
///   readout appears, the readout is already visible in it — there is nothing to
///   open.
public struct ClipboardProgressMenuAutoOpener: Equatable, Sendable {
    /// How long a paste must have been materializing before it may interrupt.
    ///
    /// Far longer than the readout's own 300 ms reveal: showing a ring costs the
    /// user nothing, taking over the screen costs them their place.
    public static let defaultMinimumElapsedToOpen: TimeInterval = 2

    /// How much work a paste must still have left before it may interrupt.
    public static let defaultMinimumRemainingToOpen: TimeInterval = 2

    private let minimumElapsedToOpen: TimeInterval
    private let minimumRemainingToOpen: TimeInterval

    /// Whether a readout is currently showing.
    private var readoutActive = false
    /// Whether the paste on screen has already had its one automatic open.
    private var openedThisPaste = false
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
    /// `menuIsOpen` whether the dropdown is on screen, and `canOpen` whether
    /// opening it is even possible — macOS hides status items it can't fit in a
    /// crowded menu bar, and a dropdown popped from a hidden item would appear
    /// detached from anything.
    public mutating func readoutChanged(
        _ readout: ClipboardProgressSnapshot?, menuIsOpen: Bool, canOpen: Bool
    ) -> ClipboardProgressMenuAction {
        guard let readout else {
            defer {
                readoutActive = false
                openedThisPaste = false
                openedByThisOpener = false
            }
            guard readoutActive, menuIsOpen, openedByThisOpener else { return .none }
            return .close
        }
        // A readout arriving while none was showing starts a new operation, which
        // earns its own single automatic open.
        if !readoutActive {
            readoutActive = true
            openedThisPaste = false
        }
        guard !openedThisPaste else { return .none }
        // Deliberately ahead of the `menuIsOpen` branch: a non-paste readout must
        // not spend the open, or a preview fetch overlapping a paste would answer
        // the paste's one chance with a dropdown the user never saw.
        guard readout.isPasteSession else { return .none }
        if menuIsOpen {
            // Nothing to open — but the paste has still *had* its showing, since
            // the controller puts the readout straight into the open dropdown.
            // Spending the open here is what stops the user's own dismissal from
            // being answered by the next update popping the dropdown back up.
            openedThisPaste = true
            return .none
        }
        // An unreachable status item, by contrast, means the readout was never
        // shown at all, so the open is not spent and a later update can still take
        // it once macOS has room for the item again.
        guard canOpen else { return .none }
        guard isWorthInterrupting(readout) else { return .none }
        openedThisPaste = true
        return .open
    }

    /// Records that the dropdown opened, and whether this opener asked for it.
    public mutating func menuOpened(automatically: Bool) {
        openedByThisOpener = automatically
    }

    /// Records that the dropdown closed, for whatever reason.
    ///
    /// A user dismissal lands here too, which is what stops the paste from ever
    /// re-opening it: `openedThisPaste` stays set for the rest of the paste.
    public mutating func menuClosed() {
        openedByThisOpener = false
    }

    /// Whether the paste has been running long enough, and has enough left to run,
    /// to be worth taking over the screen for.
    private func isWorthInterrupting(_ readout: ClipboardProgressSnapshot) -> Bool {
        guard readout.elapsedSeconds >= minimumElapsedToOpen else { return false }
        // No byte-based estimate is possible at all, so there is nothing to weigh
        // the interruption against — the elapsed floor is the whole test.
        guard readout.totalBytes > 0 else { return true }
        // Every byte is in and only the terminal is outstanding. Checked before
        // consulting the estimate because `secondsRemaining` reports `nil` both
        // here and before a rate exists, and those two mean opposite things.
        guard readout.bytesTransferred < readout.totalBytes else { return false }
        // Running this long with no measurable rate is not an operation about to
        // finish; it is a stalled or slow one, which is exactly what a standing
        // readout is for.
        guard let remaining = readout.secondsRemaining else { return true }
        return remaining >= minimumRemainingToOpen
    }
}
