import Foundation

/// The categories the VM details pane is organized into: the overview shows one
/// card per category, and each card drills into the panel holding that
/// category's full form.
package enum VMSettingsCategory: String, CaseIterable, Sendable {
    case general
    case system
    case storage
    case network
    case sharing
    case snapshots

    package var title: String {
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
    package var symbolName: String {
        switch self {
        case .general: "info.circle"
        case .system: "cpu"
        case .storage: "internaldrive"
        case .network: "network"
        case .sharing: "folder.badge.person.crop"
        case .snapshots: "clock.arrow.circlepath"
        }
    }

    /// Whether this category's settings live in `config.json`, which a revert
    /// to the Ephemeral baseline puts back — General's are the VM's name and
    /// host state, which a revert keeps, and Snapshots holds none.
    package var revertsToEphemeralBaseline: Bool {
        switch self {
        case .system, .storage, .network, .sharing: true
        case .general, .snapshots: false
        }
    }
}

/// The banner VM Settings shows above a category whose settings go back to
/// the Ephemeral baseline at the next shutdown.
package struct EphemeralSettingsBanner: Equatable {
    /// The name of the snapshot the settings go back to.
    package let baselineName: String

    /// The banner for `category`, or `nil` where none shows: the overview,
    /// a category a revert leaves alone, a VM with no `baseline`, or
    /// `dismissed`.
    package init?(category: VMSettingsCategory?, baseline: VMSnapshot?, dismissed: Bool) {
        guard let category, category.revertsToEphemeralBaseline, let baseline, !dismissed else {
            return nil
        }
        baselineName = baseline.name
    }
}
