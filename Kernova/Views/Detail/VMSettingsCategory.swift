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
}
