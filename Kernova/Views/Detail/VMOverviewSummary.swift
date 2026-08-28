import Foundation

/// A mirrored boolean: a setting a panel row writes, which an overview card may
/// carry as a switch of its own.
enum VMOverviewToggle: String, Sendable {
    case autoStart
    case ephemeralMode
    case clipboardSharing
    case clipboardPassthrough
    case dropFiles

    var title: String {
        switch self {
        case .autoStart: "Start when Kernova opens"
        case .ephemeralMode: "Ephemeral Mode"
        case .clipboardSharing: "Clipboard sharing"
        case .clipboardPassthrough: "Automatic clipboard passthrough"
        case .dropFiles: "Drag and drop files"
        }
    }
}

/// Card values the settings controller resolves from host state or an async
/// read, which the configuration alone cannot answer.
struct VMOverviewResolved: Sendable {
    /// The Mode picker's current title, which names the bridged interface.
    var networkModeTitle: String?
    /// The address the IP row currently shows, `nil` while there is none.
    var ipAddress: String?
    /// Forwarded-rule count, `nil` wherever forwarding does not apply.
    var portForwardingRuleCount: Int?
    /// The Input Devices picker's current title, `nil` for a Linux guest.
    var inputDevicesTitle: String?
    /// Whether the Mode picker hot-swaps while the VM runs, which makes the
    /// Network card's lock hint a false claim.
    var networkIsLiveSwitchable = false
    /// The banner message a category's panel currently shows, by category.
    var warnings: [VMSettingsCategory: String] = [:]
}

/// What each overview card states about a VM: the facts answering "what is this
/// VM right now", never the panel's full row list.
enum VMOverviewSummary {
    /// One key-value line on a card.
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
    }

    /// A card switch and the state it renders in — `isEnabled` false dims it
    /// where the panel's own row would be dimmed too.
    struct ToggleState: Equatable, Sendable {
        let toggle: VMOverviewToggle
        let isOn: Bool
        let isEnabled: Bool
    }

    @MainActor
    static func rows(
        for category: VMSettingsCategory, instance: VMInstance, resolved: VMOverviewResolved
    ) -> [Row] {
        let config = instance.configuration
        switch category {
        case .general:
            return [
                Row(label: "Type", value: config.guestOS.displayName),
                Row(label: "Boot mode", value: config.bootMode.displayName),
                Row(
                    label: "Created",
                    value: config.createdAt.formatted(date: .abbreviated, time: .shortened)),
            ]
        case .system:
            var rows = [
                Row(label: "CPU cores", value: "\(config.cpuCount)"),
                Row(label: "Memory", value: "\(config.memorySizeInGB) GB"),
                Row(label: "Display", value: displayValue(config)),
                Row(label: "Audio", value: audioValue(config)),
            ]
            if let title = resolved.inputDevicesTitle {
                rows.append(Row(label: "Input devices", value: title))
            }
            return rows
        case .storage:
            let disks = instance.displayedStorageDisks
            var rows: [Row] = []
            if let boot = disks.first {
                rows.append(Row(label: "Boot disk", value: boot.label))
            }
            rows.append(Row(label: "Disks", value: "\(disks.count)"))
            let removable = config.removableMedia ?? []
            rows.append(
                Row(
                    label: "Removable media",
                    value: removable.isEmpty ? "None" : "\(removable.count)"))
            return rows
        case .network:
            var rows = [Row(label: "Mode", value: resolved.networkModeTitle ?? "None")]
            if let address = resolved.ipAddress {
                rows.append(Row(label: "IP address", value: address))
            }
            if let count = resolved.portForwardingRuleCount {
                rows.append(
                    Row(
                        label: "Port forwarding",
                        value: count == 1 ? "1 rule" : "\(count) rules"))
            }
            return rows
        case .sharing:
            // Sharing states its facts in the closing line instead — see `note`.
            return []
        case .snapshots:
            let ordered = instance.snapshotManifest.ordered
            var rows = [Row(label: "Snapshots", value: "\(ordered.count)")]
            if let latest = ordered.first {
                rows.append(
                    Row(
                        label: "Latest",
                        value:
                            "\(latest.name) \u{2014} \(latest.createdAt.formatted(date: .abbreviated, time: .shortened))"
                    ))
            }
            return rows
        }
    }

    /// The live switches `category`'s card carries, in card order.
    @MainActor
    static func toggles(for category: VMSettingsCategory, instance: VMInstance) -> [ToggleState] {
        let config = instance.configuration
        switch category {
        case .general:
            let ephemeralOn = config.ephemeralModeEnabled
            return [
                ToggleState(toggle: .autoStart, isOn: config.startsAutomaticallyOnLaunch, isEnabled: true),
                // A VM with nothing to fall back to can't take the mode — but one
                // already in it can always be taken back out, matching the panel.
                ToggleState(
                    toggle: .ephemeralMode, isOn: ephemeralOn,
                    isEnabled: !instance.snapshotManifest.isEmpty || ephemeralOn),
            ]
        case .sharing:
            // Passthrough is a panel setting: its enable confirms in a sheet,
            // which is more weight than a card switch carries.
            var states = [
                ToggleState(
                    toggle: .clipboardSharing, isOn: config.clipboardSharingEnabled, isEnabled: true)
            ]
            if config.guestOS == .macOS {
                states.append(
                    ToggleState(toggle: .dropFiles, isOn: config.dropFilesEnabled, isEnabled: true))
            }
            return states
        case .system, .storage, .network, .snapshots:
            return []
        }
    }

    /// The line `category`'s card closes with, below its switches — one
    /// full-width sentence rather than a key and a value, `nil` where the
    /// category states none.
    @MainActor
    static func note(for category: VMSettingsCategory, instance: VMInstance) -> String? {
        switch category {
        case .sharing:
            let config = instance.configuration
            let count = (config.sharedDirectories ?? []).count
            let folders =
                switch count {
                case 0: "No shared folders"
                case 1: "1 shared folder"
                default: "\(count) shared folders"
                }
            // Passthrough runs only while clipboard sharing carries it, and
            // turning sharing off leaves the stored flag set — so the line
            // states what is running, as the panel dims the switch that isn't.
            let passthroughRuns =
                config.clipboardSharingEnabled && config.clipboardPassthroughEnabled
            return "Passthrough \(passthroughRuns ? "on" : "off") \u{00B7} \(folders)"
        case .general, .system, .storage, .network, .snapshots:
            return nil
        }
    }

    /// The resolution the guest boots at, or that it is sized to the window.
    private static func displayValue(_ config: VMConfiguration) -> String {
        guard !config.displaySizesToWindow else { return "Matches window" }
        let base = config.displayBaseSize
        return "\(base.width) \u{00D7} \(base.height)"
    }

    private static func audioValue(_ config: VMConfiguration) -> String {
        switch (config.audioInputEnabled, config.audioOutputEnabled) {
        case (true, true): "Input and output"
        case (true, false): "Input only"
        case (false, true): "Output only"
        case (false, false): "Off"
        }
    }
}
