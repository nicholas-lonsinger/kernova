import Foundation

/// One tab of the Settings window, in toolbar order.
package enum SettingsPane: String, CaseIterable {
    /// App-lifecycle toggles.
    case general
    /// Turning suppressed reminders back on.
    case reminders
    /// The maximum paste size.
    case clipboard
    /// The library's named networks.
    case networks
    /// The library's tags.
    case tags
    case advanced

    package var label: String {
        switch self {
        case .general: "General"
        case .reminders: "Reminders"
        case .clipboard: "Clipboard"
        case .networks: "Networks"
        case .tags: "Tags"
        case .advanced: "Advanced"
        }
    }

    package var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .reminders: "bell"
        case .clipboard: "clipboard"
        case .networks: "network"
        case .tags: "tag"
        case .advanced: "gearshape.2"
        }
    }
}

/// Where a request to show the Settings window lands.
package enum SettingsDestination: Equatable {
    case pane(SettingsPane)
    /// The Networks pane, with the row of the network `id` identifies selected
    /// when the library lists it.
    case network(UUID)

    package var pane: SettingsPane {
        switch self {
        case .pane(let pane): pane
        case .network: .networks
        }
    }
}
