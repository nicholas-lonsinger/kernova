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

/// How a key applies a written value, refusing one it cannot use.
typealias VMConfigurationKeyWrite =
    @Sendable (String, inout VMConfiguration, VMConfigurationWriteContext) throws -> Void

/// What a key's write needs beyond the configuration it edits.
struct VMConfigurationWriteContext: Sendable {
    /// The VM's restore points, which an Ephemeral Mode enable pins its
    /// baseline from.
    let snapshots: VMSnapshotManifest
}

/// One dotted configuration key: what it is called, what it reads, and what a
/// written value has to be.
///
/// ``read(_:)`` and ``write(_:_:_:)`` are inverse: writing back what a read
/// answered changes nothing, which is what makes `get` output valid `set`
/// input.
struct VMConfigurationKey: Sendable {
    /// The dotted name a caller addresses the value by.
    let name: String
    /// One line naming the unit or the accepted values.
    let summary: String
    /// When a write of this key is taken.
    let gate: VMConfigurationKeyGate
    /// Whether the key means anything for this VM at all. A key that does not
    /// apply is left out of a whole-VM read and refused when named.
    let applies: @Sendable (VMConfiguration) -> Bool
    /// The value as `set` accepts it back.
    let read: @Sendable (VMConfiguration) -> String
    /// Applies `value`, refusing with ``CommandError/invalidArgument(_:)`` when
    /// it names nothing this key takes.
    let write: VMConfigurationKeyWrite
    /// Why the value this key ended up holding cannot stand — `nil` when it
    /// can.
    ///
    /// Read off the *whole* candidate once every assignment in the batch has
    /// landed, so a key another key in the same call makes inert, or leaves
    /// naming something the VM still needs, is judged on the result rather
    /// than on the order the two arrived in. Asked only of a key the call
    /// actually moved, so writing back what a read answered stays a no-op.
    let refusalOnResult: @Sendable (VMConfiguration) -> String?

    init(
        name: String,
        summary: String,
        gate: VMConfigurationKeyGate,
        applies: @escaping @Sendable (VMConfiguration) -> Bool = { _ in true },
        read: @escaping @Sendable (VMConfiguration) -> String,
        write: @escaping VMConfigurationKeyWrite,
        refusalOnResult: @escaping @Sendable (VMConfiguration) -> String? = { _ in nil }
    ) {
        self.name = name
        self.summary = summary
        self.gate = gate
        self.applies = applies
        self.read = read
        self.write = write
        self.refusalOnResult = refusalOnResult
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
/// Every automation surface reads this one table, so a key added here becomes
/// addressable everywhere at once. Declaration order is presentation order.
enum VMConfigurationKeyRegistry {
    /// What the network mode key answers, and takes, for a VM with no network
    /// device at all.
    static let noNetworkValue = "none"

    static let keys: [VMConfigurationKey] = [
        VMConfigurationKey(
            name: "cpus",
            summary: "Virtual CPU cores, within what the guest and this Mac allow.",
            gate: .atRest,
            read: { String($0.cpuCount) },
            write: { value, config, _ in
                config.cpuCount = try ConfigurationValue.integer(
                    value, key: "cpus",
                    in: config.guestOS.minCPUCount...config.guestOS.maxCPUCount)
            }),
        VMConfigurationKey(
            name: "memory",
            summary: "Guest memory in whole gigabytes.",
            gate: .atRest,
            read: { String($0.memorySizeInGB) },
            write: { value, config, _ in
                config.memorySizeInGB = try ConfigurationValue.integer(
                    value, key: "memory",
                    in: config.guestOS.minMemoryInGB...config.guestOS.maxMemoryInGB)
            }),
        VMConfigurationKey(
            name: "display.width",
            summary: "Display width the guest lays out at; a Retina guest boots at twice this.",
            gate: .atRest,
            read: { String($0.displayBaseSize.width) },
            write: { value, config, _ in
                let width = try ConfigurationValue.integer(
                    value, key: "display.width",
                    in: DisplayBootSizing.minimumWidth...config.displayBaseSizeLimit)
                config.setDisplayBaseSize(width: width, height: config.displayBaseSize.height)
            },
            refusalOnResult: sizedToWindowRefusal("display.width")),
        VMConfigurationKey(
            name: "display.height",
            summary: "Display height the guest lays out at; a Retina guest boots at twice this.",
            gate: .atRest,
            read: { String($0.displayBaseSize.height) },
            write: { value, config, _ in
                let height = try ConfigurationValue.integer(
                    value, key: "display.height",
                    in: DisplayBootSizing.minimumHeight...config.displayBaseSizeLimit)
                config.setDisplayBaseSize(width: config.displayBaseSize.width, height: height)
            },
            refusalOnResult: sizedToWindowRefusal("display.height")),
        VMConfigurationKey(
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
            }),
        VMConfigurationKey(
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
            }),
        VMConfigurationKey(
            name: "display.autoResize",
            summary: "Let the guest follow the window as it is resized: true or false.",
            gate: .live,
            read: { String($0.displayAutoResizes) },
            write: { value, config, _ in
                config.displayAutoResizes = try ConfigurationValue.boolean(
                    value, key: "display.autoResize")
            }),
        VMConfigurationKey(
            name: "display.preference",
            summary: "Where the display opens: inline, popOut or fullscreen.",
            gate: .live,
            read: { $0.displayPreference.rawValue },
            write: { value, config, _ in
                config.displayPreference = try ConfigurationValue.choice(
                    value, key: "display.preference")
            }),
        VMConfigurationKey(
            name: "input.systemKeys",
            summary: "When system hot keys go to the guest: never, fullscreenOnly or always.",
            gate: .live,
            read: { $0.systemKeyForwarding.rawValue },
            write: { value, config, _ in
                config.systemKeyForwarding = try ConfigurationValue.choice(
                    value, key: "input.systemKeys")
            }),
        VMConfigurationKey(
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
            }),
        VMConfigurationKey(
            name: "network.bridgedInterface",
            summary: "BSD name of the interface a bridged guest attaches to; empty is automatic.",
            gate: .networkDevice,
            read: { $0.bridgedInterfaceIdentifier ?? "" },
            write: { value, config, _ in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                config.bridgedInterfaceIdentifier = trimmed.isEmpty ? nil : trimmed
            }),
        VMConfigurationKey(
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
            }),
        VMConfigurationKey(
            name: "ephemeral",
            summary: "Return the VM to its baseline snapshot at every shutdown: true or false.",
            gate: .live,
            read: { String($0.ephemeralModeEnabled) },
            write: { value, config, context in
                let enabled = try ConfigurationValue.boolean(value, key: "ephemeral")
                guard enabled else {
                    config.applyEphemeralMode(enabled: false, baseline: nil)
                    return
                }
                guard
                    let baseline = context.snapshots.defaultEphemeralBaseline(
                        preferring: config.ephemeralBaselineSnapshotID)
                else {
                    throw CommandError.invalidArgument(
                        "Ephemeral Mode returns the virtual machine to a snapshot, and this one "
                            + "has none. Take a snapshot first.")
                }
                config.applyEphemeralMode(enabled: true, baseline: baseline)
            }),
        VMConfigurationKey(
            name: "clipboard.sharing",
            summary: "Exchange clipboard text with the guest: true or false.",
            gate: .live,
            read: { String($0.clipboardSharingEnabled) },
            write: { value, config, _ in
                config.clipboardSharingEnabled = try ConfigurationValue.boolean(
                    value, key: "clipboard.sharing")
            }),
        VMConfigurationKey(
            name: "clipboard.passthrough",
            summary:
                "Forward the clipboard both ways with no window step, which needs sharing on.",
            gate: .live,
            read: { String($0.clipboardPassthroughEnabled) },
            write: { value, config, _ in
                config.clipboardPassthroughEnabled = try ConfigurationValue.boolean(
                    value, key: "clipboard.passthrough")
            }),
    ]

    /// The key `name` addresses, or `nil` when the keyspace holds none.
    static func key(named name: String) -> VMConfigurationKey? {
        keys.first { $0.name == name }
    }

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
