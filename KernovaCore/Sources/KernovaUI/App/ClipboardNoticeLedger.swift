import Foundation

/// Which surface presents each VM's refusal, so the status item presents each
/// one exactly once.
///
/// A refusal is identified by its finish's `date`, so a repeat of the same
/// kind is a new refusal.
struct ClipboardNoticeLedger {
    /// How a refusal is presented.
    enum Route: Equatable {
        /// As the notice popover — and, should the status item not carry
        /// one, not at all: the dropdown's line is the fallback.
        case notice
        /// As the open dropdown's line.
        case dropdownLine
        /// Already presented.
        case presented
    }

    private var presented: [UUID: Date] = [:]

    /// Routes the refusal raised at `date` for `vm`, recording it presented.
    mutating func route(_ date: Date, for vm: UUID, dropdownIsOpen: Bool) -> Route {
        guard presented[vm] != date else { return .presented }
        presented[vm] = date
        return dropdownIsOpen ? .dropdownLine : .notice
    }
}
