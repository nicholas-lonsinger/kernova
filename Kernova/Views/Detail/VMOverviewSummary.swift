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

/// A command a card offers at its foot, run through the same view-model gate the
/// category's panel runs it through.
enum VMOverviewAction: String, Sendable {
    case takeSnapshot

    var title: String {
        switch self {
        case .takeSnapshot: "Take Snapshot\u{2026}"
        }
    }
}

/// Values the settings pane resolves from host state, an injected service or an
/// async read, which the configuration alone cannot answer.
///
/// Produced by ``VMOverviewResolver`` and read by every surface stating one of
/// them — the overview's cards and the panel rows showing the same figure.
struct VMOverviewResolved: Sendable {
    /// The Mode picker's current title, which names the bridged interface.
    var networkModeTitle: String?
    /// What the guest's address resolves to for the mode it is on.
    var ipAddress: VMOverviewIPAddress = .unavailable
    /// Forwarded-rule count, `nil` wherever forwarding does not apply.
    var portForwardingRuleCount: Int?
    /// The boot disk's capacity, once its off-main read lands.
    var bootDiskBytes: UInt64?
    /// What each snapshot occupies, once the off-main size read lands.
    var snapshotSizes: [UUID: UInt64] = [:]
    /// What this VM's snapshots occupy together, from the same read.
    var snapshotTotalBytes: UInt64?
    /// Whether a capture is offered right now — the view model's own gate.
    var canTakeSnapshot = false
    /// What the Audio section shows beneath its input toggle.
    var micWarning: MicWarningState = .none
    /// The banner message a category's panel shows, by category.
    var warnings: [VMSettingsCategory: String] = [:]
}

/// What each overview card states about a VM: the facts answering "what is this
/// VM right now", never the panel's full row list.
///
/// Status, guest OS version, cores, memory and disk capacity are the header's
/// facts line, so no card repeats them.
enum VMOverviewSummary {
    /// A trailing copy button on a row.
    struct RowCopy: Equatable, Sendable {
        /// What the button writes to the pasteboard.
        let value: String
        /// How the button names itself, in a tooltip and to accessibility.
        let name: String
    }

    /// One key-value line on a card.
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
        /// The copy affordance trailing the value, `nil` on a row offering none.
        let copy: RowCopy?

        init(label: String, value: String, copy: RowCopy? = nil) {
            self.label = label
            self.value = value
            self.copy = copy
        }
    }

    /// A card switch and the state it renders in — `isEnabled` false dims it
    /// where the panel's own row would be dimmed too.
    struct ToggleState: Equatable, Sendable {
        let toggle: VMOverviewToggle
        let isOn: Bool
        let isEnabled: Bool
    }

    /// A card's foot command and whether it can be run right now.
    struct ActionState: Equatable, Sendable {
        let action: VMOverviewAction
        let isEnabled: Bool
    }

    @MainActor
    static func rows(
        for category: VMSettingsCategory, instance: VMInstance, resolved: VMOverviewResolved
    ) -> [Row] {
        let config = instance.configuration
        switch category {
        case .general:
            // Everything General holds is either on the header — the name and
            // the status — or one of the card's own two switches.
            return []
        case .system:
            return [
                Row(label: "Display", value: displayValue(config)),
                Row(label: "Audio", value: audioValue(config)),
            ]
        case .storage:
            let disks = instance.effectiveStorageDisks
            guard let boot = disks.first else { return [Row(label: "Disks", value: "None")] }
            let capacity = resolved.bootDiskBytes.map {
                " \u{00B7} \(DataFormatters.formatBytes($0))"
            }
            return [
                Row(label: "Boot disk", value: boot.label + (capacity ?? "")),
                Row(
                    label: "Other",
                    value:
                        "\(otherDisksValue(disks.count - 1)) \u{00B7} \(mediaValue((config.removableMedia ?? []).count))"
                ),
            ]
        case .network:
            guard config.networkEnabled, let mode = resolved.networkModeTitle else {
                return [Row(label: "Mode", value: "None")]
            }
            // The mode names the row, so the address it hands the guest is the
            // value beside it rather than a line of its own.
            let address = resolved.ipAddress.displayText
            var rows = [
                Row(
                    label: mode, value: address ?? "",
                    copy: address.map { RowCopy(value: $0, name: "Copy IP Address") })
            ]
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
            // The count and the footprint are the card's header summary.
            guard let latest = instance.snapshotManifest.ordered.first else { return [] }
            return [
                Row(
                    label: "Latest",
                    value:
                        "\(latest.name) \u{2014} \(latest.createdAt.formatted(date: .abbreviated, time: .shortened))"
                )
            ]
        }
    }

    /// The small secondary line beside `category`'s title, `nil` where the
    /// category states none.
    @MainActor
    static func headerSummary(
        for category: VMSettingsCategory, instance: VMInstance, resolved: VMOverviewResolved
    ) -> String? {
        guard category == .snapshots else { return nil }
        let count = instance.snapshotManifest.ordered.count
        guard count > 0 else { return nil }
        guard let bytes = resolved.snapshotTotalBytes else { return "\(count)" }
        return "\(count) \u{00B7} \(DataFormatters.formatBytes(bytes))"
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

    /// The command `category`'s card closes with, `nil` where it offers none.
    @MainActor
    static func action(
        for category: VMSettingsCategory, resolved: VMOverviewResolved
    ) -> ActionState? {
        // A capture works on a running VM, so the card offers it whatever the
        // pane's read-only state — the view model's own gate decides.
        guard category == .snapshots else { return nil }
        return ActionState(action: .takeSnapshot, isEnabled: resolved.canTakeSnapshot)
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

    /// How many disks follow the boot disk.
    private static func otherDisksValue(_ count: Int) -> String {
        switch count {
        case ..<1: "No other disks"
        case 1: "1 more disk"
        default: "\(count) more disks"
        }
    }

    private static func mediaValue(_ count: Int) -> String {
        switch count {
        case ..<1: "No media"
        case 1: "1 medium"
        default: "\(count) media"
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
