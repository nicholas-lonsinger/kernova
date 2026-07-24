import Foundation

/// What the status-item controller should do with its dropdown in response to a
/// change in the paste readout.
public enum PasteProgressMenuAction: Equatable, Sendable {
    case none
    /// Pop the dropdown open so the readout is visible without a click.
    case open
    /// Dismiss the dropdown this opener opened.
    case close
}

/// Decides when a paste's progress readout opens and closes the status-item
/// dropdown on its own (#643).
///
/// Pure state, so both status-item controllers share one set of rules and those
/// rules are testable without a menu bar. The rules exist to make an
/// uninvited window respectful:
///
/// - **Once per paste.** The dropdown opens when a paste's readout first
///   appears, and never again for that paste. A user who closes it has said no,
///   and re-opening over their next click would be the behavior everyone hates.
/// - **Only what it opened, it closes.** When the paste ends, a dropdown this
///   opener popped is dismissed; one the user opened themselves is left exactly
///   where they put it.
/// - **Never on top of an open menu.** If the dropdown is already showing when
///   the readout appears, the readout is already visible in it — there is
///   nothing to open.
public struct PasteProgressMenuAutoOpener: Equatable, Sendable {
    /// Whether a paste is currently showing a readout.
    private var pasteActive = false
    /// Whether this paste has already had its one automatic open.
    private var openedThisPaste = false
    /// Whether the dropdown currently on screen is the one this opener popped.
    private var openedByThisOpener = false

    /// Creates an opener with no paste in flight.
    public init() {}

    /// Folds in a change to the delivered readout.
    ///
    /// `hasReadout` is whether a snapshot is being shown, `menuIsOpen` whether
    /// the dropdown is on screen, and `canOpen` whether opening it is even
    /// possible — macOS hides status items it can't fit in a crowded menu bar,
    /// and a dropdown popped from a hidden item would appear detached from
    /// anything.
    public mutating func readoutChanged(
        hasReadout: Bool, menuIsOpen: Bool, canOpen: Bool
    ) -> PasteProgressMenuAction {
        guard hasReadout else {
            defer {
                pasteActive = false
                openedThisPaste = false
                openedByThisOpener = false
            }
            guard pasteActive, menuIsOpen, openedByThisOpener else { return .none }
            return .close
        }
        // A readout arriving while none was showing starts a new paste, which
        // earns its own single automatic open.
        if !pasteActive {
            pasteActive = true
            openedThisPaste = false
        }
        guard !openedThisPaste else { return .none }
        if menuIsOpen {
            // Nothing to open — but the paste has still *had* its showing, since
            // the controller puts the readout straight into the open dropdown.
            // Spending the open here is what stops the user's own dismissal from
            // being answered by the next update popping the dropdown back up.
            openedThisPaste = true
            return .none
        }
        // An unreachable status item, by contrast, means the readout was never
        // shown at all, so the open is not spent and a later update can still
        // take it once macOS has room for the item again.
        guard canOpen else { return .none }
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
}
