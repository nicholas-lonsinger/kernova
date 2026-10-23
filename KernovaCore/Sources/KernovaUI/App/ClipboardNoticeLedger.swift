import Foundation

/// Which surface presents each VM's refusal, so the status item presents each
/// one exactly once.
///
/// A refusal is identified by its finish's `date`, so a repeat of the same
/// kind is a new refusal.
struct ClipboardNoticeLedger {
    /// Where the status item's dropdown stands as a refusal arrives.
    enum Dropdown {
        case closed
        /// On screen and staying: it carries the refusal's line.
        case open
        /// The one the readout opened, closing as the readout ends: nothing
        /// new shows in it.
        case closing
    }

    /// How a refusal is presented.
    enum Route: Equatable {
        /// As the notice popover — and, should the status item not carry
        /// one, not at all: the dropdown's line is the fallback.
        case notice
        /// As the open dropdown's line.
        case dropdownLine
        /// Not yet: asked again once the dropdown has closed.
        case afterClose
        /// Already presented.
        case presented
    }

    private var presented: [UUID: Date] = [:]

    /// Routes the refusal raised at `date` for `vm`, recording it presented
    /// unless it must wait.
    mutating func route(_ date: Date, for vm: UUID, dropdown: Dropdown) -> Route {
        guard presented[vm] != date else { return .presented }
        switch dropdown {
        case .closing:
            return .afterClose
        case .open:
            presented[vm] = date
            return .dropdownLine
        case .closed:
            presented[vm] = date
            return .notice
        }
    }
}
