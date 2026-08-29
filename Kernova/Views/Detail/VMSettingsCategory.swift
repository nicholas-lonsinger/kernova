import Foundation

/// The categories the VM details pane is organized into: the overview shows one
/// card per category, and each card drills into the panel holding that
/// category's full form.
enum VMSettingsCategory: String, CaseIterable, Sendable {
    case general
    case system
    case storage
    case network
    case sharing
    case snapshots

    var title: String {
        switch self {
        case .general: "General"
        case .system: "System"
        case .storage: "Storage"
        case .network: "Network"
        case .sharing: "Sharing"
        case .snapshots: "Snapshots"
        }
    }

    /// SF Symbol for the card's leading glyph.
    var symbolName: String {
        switch self {
        case .general: "info.circle"
        case .system: "cpu"
        case .storage: "internaldrive"
        case .network: "network"
        case .sharing: "folder.badge.person.crop"
        case .snapshots: "clock.arrow.circlepath"
        }
    }

    /// What this category's card claims while the VM runs, as the tooltip on its
    /// lock glyph — `nil` for a category every part of which edits live.
    ///
    /// Each claim is scoped to the rows that actually lock, so it stays true
    /// beside the live controls on the same card: System keeps the serial
    /// console and auto-resize switches, Storage hot-plugs removable media,
    /// Network hot-swaps its mode, and every switch on the Sharing card is live.
    var lockHint: String? {
        switch self {
        case .general, .snapshots: nil
        case .system, .network: "Most editable when stopped"
        case .storage: "Disks editable when stopped"
        case .sharing: "Folders editable when stopped"
        }
    }

    /// Whether the panel holds a single section, whose header the panel header
    /// absorbs rather than repeating the category name inside the form.
    var isSingleSection: Bool {
        switch self {
        case .network, .snapshots: true
        case .general, .system, .storage, .sharing: false
        }
    }
}
