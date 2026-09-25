import Foundation
import KernovaKit

/// When a key takes a write, and which capability answers that for a given VM.
///
/// The predicate itself stays in ``VMCapabilityCatalog`` — this only says which
/// of them a key is gated on, and answers the presentation question
/// ``ConfigurationKeyDescriptor/editableWhileRunning`` asks.
enum VMConfigurationKeyGate: Hashable, Sendable {
    /// Only while the VM's hardware is not pinned by a live session or a saved
    /// state.
    case atRest
    /// In any state: the value is read at a moment other than boot.
    case live
    /// The network a VM joins — a hot swap on a running VM, except for the
    /// value that takes its device away.
    case networkMode
    /// A property of the network device the VM already has, which hot-swaps
    /// with the attachment.
    case networkDevice

    /// Whether a running VM can take a write of a key gated on this.
    var editableWhileRunning: Bool { self != .atRest }
}

/// What a key's write needs beyond the settings it edits.
struct VMConfigurationWriteContext: Sendable {
    /// The VM's restore points, which an Ephemeral Mode enable pins its
    /// baseline from.
    let snapshots: VMSnapshotManifest

    init(snapshots: VMSnapshotManifest) {
        self.snapshots = snapshots
    }

    /// What `instance` holds for a key's write to read.
    @MainActor
    init(_ instance: VMInstance) {
        self.init(snapshots: instance.snapshotManifest)
    }
}

/// One dotted configuration key: what it is called, what it reads, and what a
/// written value has to be.
///
/// Reading a key and writing back what it answered changes nothing, which is
/// what makes `get` output valid `set` input.
struct VMConfigurationKey: Sendable {
    /// A key whose value lives in the VM's configuration.
    struct ConfigurationField: Sendable {
        /// The value as `set` accepts it back.
        let read: @Sendable (VMConfiguration) -> String
        /// Applies a value, refusing with ``CommandError/invalidArgument(_:)``
        /// one this key cannot take.
        let write: @Sendable (String, inout VMConfiguration, VMConfigurationWriteContext) throws -> Void
        /// Why the value this key ended up holding cannot stand — `nil` when it
        /// can.
        ///
        /// Read off the *whole* candidate once every assignment in the batch has
        /// landed, so a key another key in the same call makes inert, or leaves
        /// naming something the VM still needs, is judged on the result rather
        /// than on the order the two arrived in. Asked only of a key the call
        /// actually moved, so writing back what a read answered stays a no-op.
        let refusalOnResult: @Sendable (VMConfiguration) -> String?
    }

    /// A key whose value lives in the VM's host state.
    struct HostStateField: Sendable {
        /// The value as `set` accepts it back.
        let read: @Sendable (VMHostState) -> String
        /// Parses a value into the change it makes, refusing with
        /// ``CommandError/invalidArgument(_:)`` one this key cannot take.
        ///
        /// Every refusal is made here, before any file is touched: the change
        /// itself cannot fail, so a batch's host-state half never refuses after
        /// its configuration half has landed.
        let change: @Sendable (String, VMConfigurationWriteContext) throws -> (inout VMHostState) -> Void
    }

    /// Which file holds the value, and how a written value lands there.
    enum Field: Sendable {
        case configuration(ConfigurationField)
        case hostState(HostStateField)
    }

    /// The dotted name a caller addresses the value by.
    let name: String
    /// One line naming the unit or the accepted values.
    let summary: String
    /// When a write of this key is taken.
    let gate: VMConfigurationKeyGate
    /// Whether the key means anything for this VM at all. A key that does not
    /// apply is left out of a whole-VM read and refused when named.
    let applies: @Sendable (VMConfiguration) -> Bool
    let field: Field

    /// A key over the VM's configuration.
    init(
        name: String,
        summary: String,
        gate: VMConfigurationKeyGate,
        applies: @escaping @Sendable (VMConfiguration) -> Bool = { _ in true },
        read: @escaping @Sendable (VMConfiguration) -> String,
        write:
            @escaping @Sendable (String, inout VMConfiguration, VMConfigurationWriteContext)
            throws -> Void,
        refusalOnResult: @escaping @Sendable (VMConfiguration) -> String? = { _ in nil }
    ) {
        self.name = name
        self.summary = summary
        self.gate = gate
        self.applies = applies
        field = .configuration(
            ConfigurationField(read: read, write: write, refusalOnResult: refusalOnResult))
    }

    /// A key over the VM's host state, which is always ``VMConfigurationKeyGate/live``.
    ///
    /// Its gate is asked before either file is touched, whether or not the
    /// value moves: host state commits after the configuration, where a
    /// refusal would leave the configuration landed without it. A live gate
    /// refuses only a VM still being created, cloned or imported, which has no
    /// bundle to write, so an unmoved assignment passes wherever any write
    /// could land.
    init(
        name: String,
        summary: String,
        applies: @escaping @Sendable (VMConfiguration) -> Bool = { _ in true },
        readHostState: @escaping @Sendable (VMHostState) -> String,
        changeHostState:
            @escaping @Sendable (String, VMConfigurationWriteContext) throws
            -> (inout VMHostState) -> Void
    ) {
        self.name = name
        self.summary = summary
        self.gate = .live
        self.applies = applies
        field = .hostState(HostStateField(read: readHostState, change: changeHostState))
    }

    /// The value as `set` accepts it back.
    func read(_ settings: VMSettings) -> String {
        switch field {
        case .configuration(let field): field.read(settings.configuration)
        case .hostState(let field): field.read(settings.hostState)
        }
    }

    /// Lands `value` on `settings` the way a write does, refusing with
    /// ``CommandError/invalidArgument(_:)`` a value this key cannot take.
    ///
    /// The whole-result refusal is not asked here;
    /// ``accepts(_:settings:context:)`` adds it.
    func apply(
        _ value: String, to settings: inout VMSettings, context: VMConfigurationWriteContext
    ) throws {
        switch field {
        case .configuration(let field):
            try field.write(value, &settings.configuration, context)
        case .hostState(let field):
            try field.change(value, context)(&settings.hostState)
        }
    }

    /// Whether a write of `value` to `settings` would be taken on its value
    /// alone: this key's own parsing and refusals, and the whole-result refusal
    /// when the value moved. Nothing is written, and the VM's state is not
    /// consulted — that is the verb's gate.
    func accepts(
        _ value: String, settings: VMSettings, context: VMConfigurationWriteContext
    ) -> Bool {
        guard applies(settings.configuration) else { return false }
        var candidate = settings
        do {
            try apply(value, to: &candidate, context: context)
        } catch {
            return false
        }
        guard case .configuration(let field) = field,
            field.read(candidate.configuration) != field.read(settings.configuration)
        else { return true }
        return field.refusalOnResult(candidate.configuration) == nil
    }

    /// ``accepts(_:settings:context:)`` against what `instance` holds.
    @MainActor
    func accepts(_ value: String, for instance: VMInstance) -> Bool {
        accepts(value, settings: instance.settings, context: VMConfigurationWriteContext(instance))
    }

    /// An assignment of `value` to this key.
    func assigning(_ value: String) -> ConfigurationEntry {
        ConfigurationEntry(key: name, value: value)
    }

    /// An assignment of `value` to this key, spelled the way a read answers it.
    func assigning(_ value: Bool) -> ConfigurationEntry {
        assigning(String(value))
    }

    /// How this key describes itself to a client listing the keyspace.
    var descriptor: ConfigurationKeyDescriptor {
        ConfigurationKeyDescriptor(
            name: name, summary: summary, editableWhileRunning: gate.editableWhileRunning)
    }

    /// The capability a write of `value` has to pass.
    ///
    /// Only the network mode's gate depends on the value: a device cannot be
    /// added or removed at runtime, so the mode that leaves the VM without one
    /// is not a hot swap however live the rest of the picker is.
    func capability(writing value: String) -> VMCapability {
        switch gate {
        case .atRest: .editConfiguration
        case .live: .editLiveConfiguration
        case .networkDevice: .switchNetworkMode
        case .networkMode:
            value == VMConfigurationKeyRegistry.noNetworkValue
                ? .editConfiguration : .switchNetworkMode
        }
    }
}

/// The keyspace `get` and `set` address, and the only place a configuration
/// value's name, spelling and gate are decided.
///
/// Every automation surface and every settings pane writes through
/// ``VMCommandCore/setConfiguration(_:assignments:confirmed:)`` with these keys,
/// so a key added here becomes addressable everywhere at once. ``keys`` order
/// is presentation order.
enum VMConfigurationKeyRegistry {
    /// What the network mode key answers, and takes, for a VM with no network
    /// device at all.
    static let noNetworkValue = "none"

    static let keys: [VMConfigurationKey] = [
        cpus, memory, displayWidth, displayHeight, displayHiDPI, displaySizeToWindow,
        displayAutoResize, displayPreference, audioInput, audioOutput, inputDevices,
        inputSystemKeys, serialSocket, networkMode, networkBridgedInterface, networkMAC,
        autoStart, ephemeral, ephemeralBaseline, clipboardSharing, clipboardPassthrough,
        dropFiles, agentLogForwarding, agentInstallReminder,
    ]

    /// The key `name` addresses, or `nil` when the keyspace holds none.
    static func key(named name: String) -> VMConfigurationKey? {
        keys.first { $0.name == name }
    }

    // MARK: - Resources

    static let cpus = VMConfigurationKey(
        name: "cpus",
        summary: "Virtual CPU cores, within what the guest and this Mac allow.",
        gate: .atRest,
        read: { String($0.cpuCount) },
        write: { value, config, _ in
            config.cpuCount = try ConfigurationValue.integer(
                value, key: "cpus",
                in: config.guestOS.minCPUCount...config.guestOS.maxCPUCount)
        })

    static let memory = VMConfigurationKey(
        name: "memory",
        summary: "Guest memory in whole gigabytes.",
        gate: .atRest,
        read: { String($0.memorySizeInGB) },
        write: { value, config, _ in
            config.memorySizeInGB = try ConfigurationValue.integer(
                value, key: "memory",
                in: config.guestOS.minMemoryInGB...config.guestOS.maxMemoryInGB)
        })

    // MARK: - Display

    static let displayWidth = VMConfigurationKey(
        name: "display.width",
        summary: "Display width the guest lays out at; a Retina guest boots at twice this.",
        gate: .atRest,
        read: { String($0.displayBaseSize.width) },
        write: { value, config, _ in
            let width = try ConfigurationValue.integer(
                value, key: "display.width",
                in: config.displayBaseSizeRange.width)
            config.setDisplayBaseSize(width: width, height: config.displayBaseSize.height)
        },
        refusalOnResult: sizedToWindowRefusal("display.width"))

    static let displayHeight = VMConfigurationKey(
        name: "display.height",
        summary: "Display height the guest lays out at; a Retina guest boots at twice this.",
        gate: .atRest,
        read: { String($0.displayBaseSize.height) },
        write: { value, config, _ in
            let height = try ConfigurationValue.integer(
                value, key: "display.height",
                in: config.displayBaseSizeRange.height)
            config.setDisplayBaseSize(width: config.displayBaseSize.width, height: height)
        },
        refusalOnResult: sizedToWindowRefusal("display.height"))

    static let displayHiDPI = VMConfigurationKey(
        name: "display.hidpi",
        summary: "Boot the guest display Retina-sharp: true or false.",
        gate: .atRest,
        applies: { $0.guestOS.supportsDisplayDensity },
        read: { String($0.guestOS.supportsDisplayDensity && $0.displayHiDPI) },
        write: { value, config, _ in
            let hiDPI = try ConfigurationValue.boolean(value, key: "display.hidpi")
            guard hiDPI != config.displayHiDPI else { return }
            config.displayHiDPI = hiDPI
            // While the display is sized to the window the stored trio is
            // the last boot's artifact and the next boot recomputes it at
            // this density; outside that it is the resolution the VM boots
            // at, so it carries the change now.
            guard !config.displaySizesToWindow else { return }
            config.displayResolution = DisplayBootSizing.rescaled(
                config.displayResolution, toHiDPI: hiDPI)
        })

    static let displaySizeToWindow = VMConfigurationKey(
        name: "display.sizeToWindow",
        summary: "Size the display to its window at each cold start: true or false.",
        gate: .atRest,
        read: { String($0.displaySizesToWindow) },
        write: { value, config, _ in
            let sizesToWindow = try ConfigurationValue.boolean(
                value, key: "display.sizeToWindow")
            guard sizesToWindow != config.displaySizesToWindow else { return }
            config.displaySizesToWindow = sizesToWindow
            // Leaving the mode promotes the trio from the last boot's
            // artifact to the resolution the VM boots at, so it has to
            // carry the density set while nothing was reconciling it.
            let hiDPI = config.guestOS.supportsDisplayDensity && config.displayHiDPI
            guard !sizesToWindow, hiDPI != DisplayBootSizing.isHiDPI(ppi: config.displayPPI)
            else { return }
            config.displayResolution = DisplayBootSizing.rescaled(
                config.displayResolution, toHiDPI: hiDPI)
        })

    static let displayAutoResize = VMConfigurationKey(
        name: "display.autoResize",
        summary: "Let the guest follow the window as it is resized: true or false.",
        gate: .live,
        read: { String($0.displayAutoResizes) },
        write: { value, config, _ in
            config.displayAutoResizes = try ConfigurationValue.boolean(
                value, key: "display.autoResize")
        })

    static let displayPreference = VMConfigurationKey(
        name: "display.preference",
        summary: "Where the display opens: inline, popOut or fullscreen.",
        readHostState: { $0.displayPreference.rawValue },
        changeHostState: { value, _ in
            let preference: VMDisplayPreference = try ConfigurationValue.choice(
                value, key: "display.preference")
            return { $0.displayPreference = preference }
        })

    // MARK: - Audio and Input

    static let audioInput = VMConfigurationKey(
        name: "audio.input",
        summary: "Let the guest capture from this Mac's audio input: true or false.",
        gate: .atRest,
        read: { String($0.audioInputEnabled) },
        write: { value, config, _ in
            config.audioInputEnabled = try ConfigurationValue.boolean(value, key: "audio.input")
        })

    static let audioOutput = VMConfigurationKey(
        name: "audio.output",
        summary: "Play the guest's sound through this Mac: true or false.",
        gate: .atRest,
        read: { String($0.audioOutputEnabled) },
        write: { value, config, _ in
            config.audioOutputEnabled = try ConfigurationValue.boolean(
                value, key: "audio.output")
        })

    static let inputDevices = VMConfigurationKey(
        name: "input.devices",
        summary: "The keyboard and pointer a macOS guest sees: automatic, mac or usb.",
        gate: .atRest,
        applies: { $0.guestOS == .macOS },
        read: { $0.inputDeviceMode.rawValue },
        write: { value, config, _ in
            config.inputDeviceMode = try ConfigurationValue.choice(value, key: "input.devices")
        })

    static let inputSystemKeys = VMConfigurationKey(
        name: "input.systemKeys",
        summary: "When system hot keys go to the guest: never, fullscreenOnly or always.",
        gate: .live,
        read: { $0.systemKeyForwarding.rawValue },
        write: { value, config, _ in
            config.systemKeyForwarding = try ConfigurationValue.choice(
                value, key: "input.systemKeys")
        })

    static let serialSocket = VMConfigurationKey(
        name: "serial.socket",
        summary: "Expose the serial port over a local UNIX socket: true or false.",
        gate: .live,
        read: { String($0.serialSocketRelayEnabled) },
        write: { value, config, _ in
            config.serialSocketRelayEnabled = try ConfigurationValue.boolean(
                value, key: "serial.socket")
        })

    // MARK: - Network

    static let networkMode = VMConfigurationKey(
        name: "network.mode",
        summary: "The network the guest joins: none, shared, bridged or hostOnly.",
        gate: .networkMode,
        read: { $0.effectiveNetworkMode?.rawValue ?? noNetworkValue },
        write: { value, config, _ in
            guard value != noNetworkValue else {
                config.applyNetworkMode(nil)
                return
            }
            config.applyNetworkMode(
                try ConfigurationValue.choice(
                    value, key: "network.mode", also: [noNetworkValue]))
        })

    static let networkBridgedInterface = VMConfigurationKey(
        name: "network.bridgedInterface",
        summary: "BSD name of the interface a bridged guest attaches to; empty is automatic.",
        gate: .networkDevice,
        read: { $0.bridgedInterfaceIdentifier ?? "" },
        write: { value, config, _ in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            config.bridgedInterfaceIdentifier = trimmed.isEmpty ? nil : trimmed
        })

    static let networkMAC = VMConfigurationKey(
        name: "network.mac",
        summary:
            "The guest's MAC address as six colon-separated hex pairs; empty removes it.",
        gate: .atRest,
        read: { $0.macAddress ?? "" },
        write: { value, config, _ in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                config.macAddress = nil
                return
            }
            guard let normalized = GuestMACAddress.normalized(trimmed) else {
                throw CommandError.invalidArgument(
                    "\u{201C}\(value)\u{201D} is not a MAC address a guest can send from. "
                        + "Give six colon-separated hex pairs, unicast and not all zero.")
            }
            config.macAddress = normalized
        },
        refusalOnResult: { config in
            guard config.networkEnabled, config.macAddress == nil else { return nil }
            return
                "A guest with a network device sends from a MAC address, and network.mac "
                + "names none. Give an address, or set network.mode=\(noNetworkValue) to take "
                + "the device away."
        })

    // MARK: - Startup

    static let autoStart = VMConfigurationKey(
        name: "autoStart",
        summary: "Start the VM each time Kernova opens: true or false.",
        readHostState: { String($0.startsAutomaticallyOnLaunch) },
        changeHostState: { value, _ in
            let enabled = try ConfigurationValue.boolean(value, key: "autoStart")
            return { $0.startsAutomaticallyOnLaunch = enabled }
        })

    static let ephemeral = VMConfigurationKey(
        name: "ephemeral",
        summary: "Return the VM to its baseline snapshot at every shutdown: true or false.",
        readHostState: { String($0.ephemeralModeEnabled) },
        changeHostState: { value, context in
            let enabled = try ConfigurationValue.boolean(value, key: "ephemeral")
            guard enabled else {
                return { $0.applyEphemeralMode(enabled: false, baseline: nil) }
            }
            let snapshots = context.snapshots
            guard snapshots.defaultEphemeralBaseline(preferring: nil) != nil else {
                throw CommandError.invalidArgument(
                    "Ephemeral Mode returns the virtual machine to a snapshot, and this one "
                        + "has none. Take a snapshot first.")
            }
            return { hostState in
                hostState.applyEphemeralMode(
                    enabled: true,
                    baseline: snapshots.defaultEphemeralBaseline(
                        preferring: hostState.ephemeralBaselineSnapshotID))
            }
        })

    static let ephemeralBaseline = VMConfigurationKey(
        name: "ephemeral.baseline",
        summary:
            "The snapshot Ephemeral Mode returns to, by identifier or name; setting one turns "
            + "the mode on.",
        readHostState: { $0.ephemeralBaselineSnapshotID?.uuidString ?? "" },
        changeHostState: { value, context in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // What a read answers while the mode is off, so it writes back as
            // no change.
            guard !trimmed.isEmpty else { return { _ in } }
            switch SnapshotSelection(
                trimmed, in: context.snapshots.ordered, id: \.id, name: \.name)
            {
            case .found(let snapshot):
                return { $0.applyEphemeralMode(enabled: true, baseline: snapshot.id) }
            case .notFound:
                throw CommandError.invalidArgument(
                    "This virtual machine has no snapshot \u{201C}\(trimmed)\u{201D}.")
            case .ambiguous(let candidates):
                throw CommandError.invalidArgument(
                    "\u{201C}\(trimmed)\u{201D} names \(candidates.count) snapshots. "
                        + "Use one of their identifiers instead: "
                        + candidates.map { "\($0.name) (\($0.id.uuidString))" }
                        .joined(separator: ", ") + ".")
            }
        })

    // MARK: - Guest Agent

    static let clipboardSharing = VMConfigurationKey(
        name: "clipboard.sharing",
        summary: "Exchange clipboard text with the guest: true or false.",
        gate: .live,
        read: { String($0.clipboardSharingEnabled) },
        write: { value, config, _ in
            config.clipboardSharingEnabled = try ConfigurationValue.boolean(
                value, key: "clipboard.sharing")
        })

    static let clipboardPassthrough = VMConfigurationKey(
        name: "clipboard.passthrough",
        summary:
            "Forward the clipboard both ways with no window step, which needs sharing on.",
        gate: .live,
        read: { String($0.clipboardPassthroughEnabled) },
        write: { value, config, _ in
            config.clipboardPassthroughEnabled = try ConfigurationValue.boolean(
                value, key: "clipboard.passthrough")
        },
        refusalOnResult: { config in
            guard config.clipboardPassthroughEnabled, !config.clipboardSharingEnabled
            else { return nil }
            return
                "Automatic clipboard passthrough rides on clipboard sharing, which is off. "
                + "Set clipboard.sharing=true as well."
        })

    static let dropFiles = VMConfigurationKey(
        name: "dropFiles",
        summary: "Send files dropped on the display to the guest's Downloads: true or false.",
        gate: .live,
        applies: { $0.guestOS == .macOS },
        read: { String($0.dropFilesEnabled) },
        write: { value, config, _ in
            config.dropFilesEnabled = try ConfigurationValue.boolean(value, key: "dropFiles")
        })

    static let agentLogForwarding = VMConfigurationKey(
        name: "agent.logForwarding",
        summary: "Forward the guest agent's log records to this Mac: true or false.",
        gate: .live,
        applies: { $0.guestOS == .macOS },
        read: { String($0.agentLogForwardingEnabled) },
        write: { value, config, _ in
            config.agentLogForwardingEnabled = try ConfigurationValue.boolean(
                value, key: "agent.logForwarding")
        })

    static let agentInstallReminder = VMConfigurationKey(
        name: "agent.installReminder",
        summary: "Remind in the sidebar while the guest agent has not connected: true or false.",
        applies: { $0.guestOS == .macOS },
        readHostState: { String(!$0.agentInstallNudgeDismissed) },
        changeHostState: { value, _ in
            let reminds = try ConfigurationValue.boolean(value, key: "agent.installReminder")
            return { $0.agentInstallNudgeDismissed = !reminds }
        })

    /// The refusal a size key owes while the display is sized to its window:
    /// every cold start recomputes the trio from the window, so a size written
    /// here would be overwritten before the guest ever laid out at it.
    private static func sizedToWindowRefusal(_ key: String) -> @Sendable (VMConfiguration) -> String? {
        { config in
            guard config.displaySizesToWindow else { return nil }
            return
                "\(key) is recomputed from the window at every cold start while "
                + "display.sizeToWindow is on. Set display.sizeToWindow=false to choose the size."
        }
    }
}

/// Turning a written value into a typed one, refusing rather than clamping —
/// a command line states what it would not do instead of doing something else.
enum ConfigurationValue {
    /// The spellings a written boolean takes, and the two it is read back as.
    private static let trueSpellings: Set<String> = ["true", "yes", "on", "1"]
    private static let falseSpellings: Set<String> = ["false", "no", "off", "0"]

    static func boolean(_ text: String, key: String) throws -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trueSpellings.contains(normalized) { return true }
        if falseSpellings.contains(normalized) { return false }
        throw CommandError.invalidArgument(
            "\(key) takes true or false, not \u{201C}\(text)\u{201D}.")
    }

    static func integer(_ text: String, key: String, in range: ClosedRange<Int>) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            throw CommandError.invalidArgument(
                "\(key) takes a whole number, not \u{201C}\(text)\u{201D}.")
        }
        guard range.contains(value) else {
            throw CommandError.invalidArgument(
                "\(key) takes \(range.lowerBound) to \(range.upperBound) on this virtual machine, "
                    + "and \(value) is outside that.")
        }
        return value
    }

    /// `text` as one of `T`'s cases, listing every accepted spelling when it
    /// names none — `also` for a spelling the caller handles outside the type.
    static func choice<T: RawRepresentable & CaseIterable>(
        _ text: String, key: String, also: [String] = []
    ) throws -> T where T.RawValue == String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = T(rawValue: trimmed) else {
            let accepted = (also + T.allCases.map(\.rawValue)).joined(separator: ", ")
            throw CommandError.invalidArgument(
                "\(key) takes one of \(accepted), not \u{201C}\(text)\u{201D}.")
        }
        return value
    }
}
