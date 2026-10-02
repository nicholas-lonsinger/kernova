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
    /// Which network of its mode the device joins: a hot swap on a running VM,
    /// and a move a suspended VM of some modes takes beside its saved state.
    case networkMembership

    /// Whether a running VM can take a write of a key gated on this.
    var editableWhileRunning: Bool { self != .atRest }
}

/// What a key's write needs beyond the settings it edits.
struct VMConfigurationWriteContext: Sendable {
    /// The VM's restore points, which an Ephemeral Mode enable pins its
    /// baseline from.
    let snapshots: VMSnapshotManifest
    /// What this build authorizes, which decides the networks a write may
    /// move the VM onto.
    let entitlements: EntitlementService
    /// The library's named networks, which a membership names and whose kind
    /// a VM on one runs in.
    let networks: [VMNamedNetwork]

    init(
        snapshots: VMSnapshotManifest, entitlements: EntitlementService, networks: [VMNamedNetwork]
    ) {
        self.snapshots = snapshots
        self.entitlements = entitlements
        self.networks = networks
    }

    /// What `instance` holds, in a build authorizing `entitlements` whose
    /// library lists `networks`, for a key's write to read.
    @MainActor
    init(_ instance: VMInstance, entitlements: EntitlementService, networks: [VMNamedNetwork]) {
        self.init(
            snapshots: instance.snapshotManifest, entitlements: entitlements, networks: networks)
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
        let refusalOnResult: @Sendable (VMConfiguration, VMConfigurationWriteContext) -> String?
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
    /// When a write of this key is taken on a guest of each OS.
    let gate: @Sendable (VMGuestOS) -> VMConfigurationKeyGate
    /// Whether the key means anything for a guest of each OS at all. A key
    /// that does not apply is left out of a whole-VM read and refused when named.
    private let appliesToGuest: @Sendable (VMGuestOS) -> Bool
    let field: Field

    /// A key over the VM's configuration, taken under `gate` on every guest.
    init(
        name: String,
        summary: String,
        gate: VMConfigurationKeyGate,
        applies: @escaping @Sendable (VMGuestOS) -> Bool = { _ in true },
        read: @escaping @Sendable (VMConfiguration) -> String,
        write:
            @escaping @Sendable (String, inout VMConfiguration, VMConfigurationWriteContext)
            throws -> Void,
        refusalOnResult: @escaping @Sendable (VMConfiguration, VMConfigurationWriteContext) -> String? = {
            _, _ in nil
        }
    ) {
        self.init(
            name: name, summary: summary, gateByGuest: { _ in gate }, applies: applies, read: read,
            write: write, refusalOnResult: refusalOnResult)
    }

    /// A key over the VM's configuration whose gate depends on the guest OS.
    init(
        name: String,
        summary: String,
        gateByGuest gate: @escaping @Sendable (VMGuestOS) -> VMConfigurationKeyGate,
        applies: @escaping @Sendable (VMGuestOS) -> Bool = { _ in true },
        read: @escaping @Sendable (VMConfiguration) -> String,
        write:
            @escaping @Sendable (String, inout VMConfiguration, VMConfigurationWriteContext)
            throws -> Void,
        refusalOnResult: @escaping @Sendable (VMConfiguration, VMConfigurationWriteContext) -> String? = {
            _, _ in nil
        }
    ) {
        self.name = name
        self.summary = summary
        self.gate = gate
        self.appliesToGuest = applies
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
        applies: @escaping @Sendable (VMGuestOS) -> Bool = { _ in true },
        readHostState: @escaping @Sendable (VMHostState) -> String,
        changeHostState:
            @escaping @Sendable (String, VMConfigurationWriteContext) throws
            -> (inout VMHostState) -> Void
    ) {
        self.name = name
        self.summary = summary
        self.gate = { _ in .live }
        self.appliesToGuest = applies
        field = .hostState(HostStateField(read: readHostState, change: changeHostState))
    }

    /// Whether the key means anything for a `guestOS` guest.
    func applies(to guestOS: VMGuestOS) -> Bool { appliesToGuest(guestOS) }

    /// Whether the key means anything for the VM `configuration` describes.
    func applies(_ configuration: VMConfiguration) -> Bool { applies(to: configuration.guestOS) }

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
        return field.refusalOnResult(candidate.configuration, context) == nil
    }

    /// ``accepts(_:settings:context:)`` against what `instance` holds, in a
    /// build authorizing `entitlements` whose library lists `networks`.
    @MainActor
    func accepts(
        _ value: String, for instance: VMInstance, entitlements: EntitlementService,
        networks: [VMNamedNetwork]
    ) -> Bool {
        accepts(
            value, settings: instance.settings,
            context: VMConfigurationWriteContext(
                instance, entitlements: entitlements, networks: networks))
    }

    /// An assignment of `value` to this key.
    func assigning(_ value: String) -> ConfigurationEntry {
        ConfigurationEntry(key: name, value: value)
    }

    /// An assignment of `value` to this key, spelled the way a read answers it.
    func assigning(_ value: Bool) -> ConfigurationEntry {
        assigning(String(value))
    }

    /// How this key describes itself to a client listing the keyspace, which
    /// names no VM: whether a running VM takes it, for each guest it applies to.
    var descriptor: ConfigurationKeyDescriptor {
        ConfigurationKeyDescriptor(
            name: name, summary: summary,
            editableWhileRunning: Dictionary(
                uniqueKeysWithValues: VMGuestOS.allCases.filter(applies(to:)).map {
                    ($0.rawValue, gate($0).editableWhileRunning)
                }))
    }

    /// What a write of `value` on a `guestOS` guest touches — the edit classes
    /// the permit for it is minted for, read off ``capability(writing:for:)``.
    func editClasses(writing value: String, for guestOS: VMGuestOS) -> VMEditClasses {
        let capability = capability(writing: value, for: guestOS)
        guard let classes = capability.editClasses else {
            assertionFailure("The gate capability \(capability) names no edit class")
            return .all
        }
        return classes
    }

    /// The capability a write of `value` on a `guestOS` guest has to pass.
    ///
    /// Only the network mode's gate depends on the value: a device cannot be
    /// added or removed at runtime, so the mode that leaves the VM without one
    /// is not a hot swap however live the rest of the picker is.
    func capability(writing value: String, for guestOS: VMGuestOS) -> VMCapability {
        switch gate(guestOS) {
        case .atRest: .editConfiguration
        case .live: .editLiveConfiguration
        case .networkDevice: .switchNetworkMode
        case .networkMembership: .switchNetworkMembership
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
/// ``VMCommandCore/setConfiguration(_:assignments:consent:)`` with these keys,
/// so a key added here becomes addressable everywhere at once. ``keys`` order
/// is presentation order.
enum VMConfigurationKeyRegistry {
    /// What the network mode key answers, and takes, for a VM with no network
    /// device at all.
    static let noNetworkValue = "none"

    static let keys: [VMConfigurationKey] = [
        cpus, memory, displayWidth, displayHeight, displayHiDPI, displaySizeToWindow,
        displayAutoResize, displayPreference, audioInput, audioOutput, inputDevices,
        inputSystemKeys, serialSocket, networkMode, networkBridgedInterface, networkMembership,
        networkMAC,
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
        summary: "Virtual CPU cores, within what Virtualization allows on this Mac.",
        gate: .atRest,
        read: { String($0.cpuCount) },
        write: { value, config, _ in
            config.cpuCount = try ConfigurationValue.integer(
                value, key: "cpus", in: VMResourceLimits.cpuCount)
        })

    static let memory = VMConfigurationKey(
        name: "memory",
        summary: "Guest memory in gigabytes, to the nearest megabyte: 8, or 1.5 for 1536 MB.",
        gate: .atRest,
        read: { $0.memorySizeInGB.gibibytesText },
        write: { value, config, _ in
            config.memorySizeInGB = try ConfigurationValue.memorySize(
                value, key: "memory", in: VMResourceLimits.memorySize)
        })

    // MARK: - Display

    static let displayWidth = VMConfigurationKey(
        name: "display.width",
        summary: "Display width the guest lays out at; a Retina guest boots at twice this.",
        gate: .atRest,
        read: { String($0.displayBaseSize.width) },
        write: { value, config, _ in
            let width = try ConfigurationValue.integer(
                value, key: "display.width", in: config.displayBaseSizeBounds)
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
                value, key: "display.height", in: config.displayBaseSizeBounds)
            config.setDisplayBaseSize(width: config.displayBaseSize.width, height: height)
        },
        refusalOnResult: sizedToWindowRefusal("display.height"))

    static let displayHiDPI = VMConfigurationKey(
        name: "display.hidpi",
        summary: "Boot the guest display Retina-sharp: true or false.",
        gate: .atRest,
        applies: { $0.supportsDisplayDensity },
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
        applies: { $0 == .macOS },
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
        write: { value, config, context in
            guard value != noNetworkValue else {
                config.applyNetworkMode(nil)
                return
            }
            let before = config
            config.applyNetworkMode(
                try ConfigurationValue.choice(
                    value, key: "network.mode", also: [noNetworkValue]))
            try requireAttachableNetwork(movingFrom: before, to: config, context: context)
        },
        refusalOnResult: namedNetworkRefusal)

    static let networkBridgedInterface = VMConfigurationKey(
        name: "network.bridgedInterface",
        summary: "BSD name of the interface a bridged guest attaches to; empty is automatic.",
        gate: .networkDevice,
        read: { $0.bridgedInterfaceIdentifier ?? "" },
        write: { value, config, _ in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            config.bridgedInterfaceIdentifier = trimmed.isEmpty ? nil : trimmed
        })

    static let networkMembership = VMConfigurationKey(
        name: "network.membership",
        summary:
            "Which network of its mode a shared or hostOnly guest joins: common, the one every "
            + "other guest in the mode joins; isolated, a network of its own; or a named "
            + "network, by name or identifier, which only the guests naming it join.",
        gate: .networkMembership,
        read: { $0.networkMembership.rawValue },
        write: { value, config, context in
            let before = config
            config.networkMembership = try membership(value, context: context)
            try requireAttachableNetwork(movingFrom: before, to: config, context: context)
        },
        refusalOnResult: membershipRefusal)

    /// The membership `value` spells: `common`, `isolated`, or a named
    /// network the library lists, by identifier or by name.
    ///
    /// The identifier a VM already names is taken back even when the library
    /// no longer lists it, so a read written back stays a no-op.
    private static func membership(
        _ value: String, context: VMConfigurationWriteContext
    ) throws -> VMNetworkMembership {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let membership = VMNetworkMembership(rawValue: trimmed) { return membership }
        if let network = context.networks.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return .network(network.id)
        }
        let named = context.networks.map(\.name)
        throw CommandError.invalidArgument(
            "network.membership takes common, isolated, or a network\u{2019}s name or identifier"
                + (named.isEmpty ? "" : " (\(named.joined(separator: ", ")))")
                + ", not \u{201C}\(value)\u{201D}.")
    }

    /// Why the network the VM ends up on cannot stand, judged once both
    /// network keys have landed: a named network the library lists runs its
    /// VMs in its own kind, so a VM joins it only in that mode
    /// (``VMNamedNetwork/kind``), and a VM joining a named network joins one
    /// the library lists.
    private static func namedNetworkRefusal(
        _ config: VMConfiguration, context: VMConfigurationWriteContext
    ) -> String? {
        guard let joined = config.joinedNetwork, case .vmnet(let id) = joined,
            case .named(let networkID) = id.scope
        else { return nil }
        guard let network = context.networks.first(where: { $0.id == networkID }) else {
            return unlistedNetworkRefusal
        }
        guard network.kind != id.kind else { return nil }
        return
            "\u{201C}\(network.name)\u{201D} is a \(network.mode.rawValue) network, so a guest on it "
            + "runs in that mode. Set network.mode=\(network.mode.rawValue) as well, or choose "
            + "another network.membership."
    }

    /// ``namedNetworkRefusal(_:context:)``, and a membership naming a network
    /// the library does not list whatever the VM's mode — the key's own value
    /// is refused where it is entered, not at the mode change that would make
    /// it count.
    private static func membershipRefusal(
        _ config: VMConfiguration, context: VMConfigurationWriteContext
    ) -> String? {
        if let networkID = config.networkMembership.namedNetwork,
            !context.networks.contains(where: { $0.id == networkID })
        {
            return unlistedNetworkRefusal
        }
        return namedNetworkRefusal(config, context: context)
    }

    private static let unlistedNetworkRefusal =
        "network.membership names a network this library does not list. "
        + "Set network.membership to common, isolated, or a network it lists."

    /// Refuses a write that moves the VM onto a network this build cannot
    /// attach (``EntitlementService/canAttach(_:)``), where the user enters it
    /// rather than at the next start (docs/NETWORKING.md). A VM already on
    /// such a network can still be moved off it, and a write that leaves the
    /// network where it is stays a no-op.
    private static func requireAttachableNetwork(
        movingFrom old: VMConfiguration, to new: VMConfiguration,
        context: VMConfigurationWriteContext
    ) throws {
        guard let network = new.joinedNetwork, network != old.joinedNetwork,
            !context.entitlements.canAttach(network)
        else { return }
        throw CommandError.unsupportedByBuild(capability: network.entitledCapability)
    }

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
        refusalOnResult: { config, _ in
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
        gateByGuest: { $0.sharesClipboardThroughDevice ? .atRest : .live },
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
        refusalOnResult: { config, _ in
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
        applies: { $0 == .macOS },
        read: { String($0.dropFilesEnabled) },
        write: { value, config, _ in
            config.dropFilesEnabled = try ConfigurationValue.boolean(value, key: "dropFiles")
        })

    static let agentLogForwarding = VMConfigurationKey(
        name: "agent.logForwarding",
        summary: "Forward the guest agent's log records to this Mac: true or false.",
        gate: .live,
        applies: { $0 == .macOS },
        read: { String($0.agentLogForwardingEnabled) },
        write: { value, config, _ in
            config.agentLogForwardingEnabled = try ConfigurationValue.boolean(
                value, key: "agent.logForwarding")
        })

    static let agentInstallReminder = VMConfigurationKey(
        name: "agent.installReminder",
        summary: "Remind in the sidebar while the guest agent has not connected: true or false.",
        applies: { $0 == .macOS },
        readHostState: { String(!$0.agentInstallNudgeDismissed) },
        changeHostState: { value, _ in
            let reminds = try ConfigurationValue.boolean(value, key: "agent.installReminder")
            return { $0.agentInstallNudgeDismissed = !reminds }
        })

    /// The refusal a size key owes while the display is sized to its window:
    /// every cold start recomputes the trio from the window, so a size written
    /// here would be overwritten before the guest ever laid out at it.
    private static func sizedToWindowRefusal(
        _ key: String
    ) -> @Sendable (VMConfiguration, VMConfigurationWriteContext) -> String? {
        { config, _ in
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

    static func integer(_ text: String, key: String, in bounds: InclusiveBounds<Int>) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            throw CommandError.invalidArgument(
                "\(key) takes a whole number, not \u{201C}\(text)\u{201D}.")
        }
        guard bounds.contains(value) else {
            throw outOfBounds(key: key, lower: String(bounds.lower), upper: String(bounds.upper), value: trimmed)
        }
        return value
    }

    /// `text` as a decimal count of gigabytes, rounded to the nearest megabyte.
    static func memorySize(
        _ text: String, key: String, in bounds: InclusiveBounds<VMMemorySize>
    ) throws -> VMMemorySize {
        guard let value = VMMemorySize(gibibytesText: text) else {
            throw CommandError.invalidArgument(
                "\(key) takes a number of gigabytes, not \u{201C}\(text)\u{201D}.")
        }
        guard bounds.contains(value) else {
            throw outOfBounds(
                key: key, lower: bounds.lower.gibibytesText, upper: bounds.upper.gibibytesText,
                value: value.gibibytesText)
        }
        return value
    }

    private static func outOfBounds(key: String, lower: String, upper: String, value: String) -> CommandError {
        .invalidArgument("\(key) takes \(lower) to \(upper), and \(value) is outside that.")
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
