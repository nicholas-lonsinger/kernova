import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The `get`/`set` keyspace on its own: what each key reads, what it accepts,
/// and what it refuses — with no library, no VM and no wire in sight.
@Suite("VMConfigurationKeyRegistry Tests", .caseScoped)
@MainActor
struct VMConfigurationKeyRegistryTests {
    /// A macOS configuration in the shape every path in the app produces one:
    /// a network device with an address, a resolution the density agrees
    /// with, and resources inside this host's bounds, which CI runners set
    /// lower than a development Mac.
    private func makeConfiguration(guestOS: VMGuestOS = .macOS) -> VMConfiguration {
        VMConfiguration(
            name: "Alpha", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi,
            cpuCount: guestOS.defaultCPUCount, memorySizeInGB: guestOS.defaultMemorySize,
            displayWidth: 3840, displayHeight: 2400,
            displayPPI: guestOS == .macOS
                ? DisplayBootSizing.hiDPIPixelsPerInch : DisplayBootSizing.standardPixelsPerInch,
            displaySizesToWindow: false, displayHiDPI: guestOS == .macOS,
            networkEnabled: true, networkMode: .shared, macAddress: "aa:bb:cc:dd:ee:ff")
    }

    private func makeManifest() -> VMSnapshotManifest {
        let snapshot = VMSnapshot(
            name: "Baseline", createdAt: Date(timeIntervalSince1970: 1), kind: .cold, macAddress: nil)
        return VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id)
    }

    private func context(
        _ manifest: VMSnapshotManifest? = nil, entitlements: EntitlementService = .entitled,
        networks: [VMNamedNetwork] = []
    ) -> VMConfigurationWriteContext {
        VMConfigurationWriteContext(
            snapshots: manifest ?? makeManifest(), entitlements: entitlements, networks: networks)
    }

    /// Writes `key` into whichever half of `settings` holds it.
    private func write(
        _ key: VMConfigurationKey, _ value: String, to settings: inout VMSettings,
        manifest: VMSnapshotManifest? = nil
    ) throws {
        switch key.field {
        case .configuration(let field):
            try field.write(value, &settings.configuration, context(manifest))
        case .hostState(let field):
            try field.change(value, context(manifest))(&settings.hostState)
        }
    }

    /// Why `key`'s result cannot stand on `config`, for a configuration key.
    private func resultRefusal(_ key: VMConfigurationKey, on config: VMConfiguration) -> String? {
        guard case .configuration(let field) = key.field else {
            Issue.record("\(key.name) is not a configuration key")
            return nil
        }
        return field.refusalOnResult(config, context())
    }

    /// Writes a configuration key, on a VM whose host state is the default.
    private func write(
        _ key: VMConfigurationKey, _ value: String, to config: inout VMConfiguration,
        manifest: VMSnapshotManifest? = nil
    ) throws {
        var settings = VMSettings(configuration: config, hostState: VMHostState())
        try write(key, value, to: &settings, manifest: manifest)
        config = settings.configuration
    }

    /// Reads a configuration key, on a VM whose host state is the default.
    private func read(_ key: VMConfigurationKey, _ config: VMConfiguration) -> String {
        key.read(VMSettings(configuration: config, hostState: VMHostState()))
    }

    // MARK: - Round trip

    /// Every key's read written straight back leaves `original` untouched.
    private func expectEveryKeyRoundTrips(
        _ original: VMSettings, manifest: VMSnapshotManifest? = nil, _ label: String = ""
    ) throws {
        for key in VMConfigurationKeyRegistry.keys where key.applies(original.configuration) {
            var settings = original
            try write(key, key.read(original), to: &settings, manifest: manifest)
            #expect(settings == original, "\(key.name)\(label)")
        }
    }

    @Test("Every key writes back what it read without changing anything")
    func everyKeyRoundTrips() throws {
        for guestOS in VMGuestOS.allCases {
            try expectEveryKeyRoundTrips(
                VMSettings(
                    configuration: makeConfiguration(guestOS: guestOS), hostState: VMHostState()),
                " on \(guestOS.rawValue)")
        }
    }

    @Test("Every key writes back what it read on a VM with no network device")
    func everyKeyRoundTripsWithoutANetworkDevice() throws {
        var original = makeConfiguration()
        original.networkEnabled = false
        original.macAddress = nil
        original.bridgedInterfaceIdentifier = nil

        try expectEveryKeyRoundTrips(
            VMSettings(configuration: original, hostState: VMHostState()))
    }

    @Test("Every key writes back what it read on an ephemeral, sharing VM")
    func everyKeyRoundTripsWithEveryFlagOn() throws {
        let manifest = makeManifest()
        var original = makeConfiguration()
        original.clipboardSharingEnabled = true
        original.clipboardPassthroughEnabled = true
        original.displaySizesToWindow = true
        original.displayAutoResizes = false
        original.systemKeyForwarding = .fullscreenOnly
        original.networkMode = .bridged
        original.bridgedInterfaceIdentifier = "en1"
        var hostState = VMHostState(displayPreference: .fullscreen)
        hostState.applyEphemeralMode(
            enabled: true, baseline: manifest.defaultEphemeralBaseline(preferring: nil))

        try expectEveryKeyRoundTrips(
            VMSettings(configuration: original, hostState: hostState), manifest: manifest)
    }

    // MARK: - Namespace

    @Test("Key names are unique and lookup answers by name")
    func keyNamesAreUnique() {
        let names = VMConfigurationKeyRegistry.keys.map(\.name)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(VMConfigurationKeyRegistry.key(named: name)?.name == name)
        }
        #expect(VMConfigurationKeyRegistry.key(named: "cpu") == nil)
    }

    @Test("The keyspace listing answers, per guest the key applies to, whether a running VM takes it")
    func descriptorsAnswerPerGuest() throws {
        func listing(_ name: String) throws -> [String: Bool] {
            let key = try #require(VMConfigurationKeyRegistry.key(named: name))
            #expect(key.descriptor.name == key.name)
            #expect(key.descriptor.summary == key.summary)
            return key.descriptor.editableWhileRunning
        }
        #expect(try listing("cpus") == ["macOS": false, "linux": false])
        #expect(try listing("clipboard.sharing") == ["macOS": true, "linux": false])
        #expect(try listing("network.mode") == ["macOS": true, "linux": true])
        #expect(try listing("ephemeral") == ["macOS": true, "linux": true])
        #expect(try listing("dropFiles") == ["macOS": true])
        for key in VMConfigurationKeyRegistry.keys { #expect(!key.summary.isEmpty) }
    }

    @Test("Each gate names the capability that decides it")
    func gatesNameTheirCapability() throws {
        let cpus = try #require(VMConfigurationKeyRegistry.key(named: "cpus"))
        #expect(cpus.capability(writing: "4", for: .macOS) == .editConfiguration)

        let ephemeral = try #require(VMConfigurationKeyRegistry.key(named: "ephemeral"))
        #expect(ephemeral.capability(writing: "true", for: .macOS) == .editLiveConfiguration)

        let bridged = try #require(
            VMConfigurationKeyRegistry.key(named: "network.bridgedInterface"))
        #expect(bridged.capability(writing: "en0", for: .macOS) == .switchNetworkMode)

        // A hot swap between attachable modes, but taking the device away is
        // not one — devices cannot be added or removed at runtime.
        let mode = try #require(VMConfigurationKeyRegistry.key(named: "network.mode"))
        #expect(mode.capability(writing: "bridged", for: .macOS) == .switchNetworkMode)
        #expect(mode.capability(writing: "none", for: .macOS) == .editConfiguration)

        // A Linux guest's clipboard rides a console device the machine is
        // built with; a macOS guest's rides the agent's channel.
        let clipboard = try #require(VMConfigurationKeyRegistry.key(named: "clipboard.sharing"))
        #expect(clipboard.capability(writing: "true", for: .macOS) == .editLiveConfiguration)
        #expect(clipboard.capability(writing: "true", for: .linux) == .editConfiguration)
    }

    // MARK: - Values

    @Test("Booleans take every spelling and read back as true or false")
    func booleansTakeEverySpelling() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "display.autoResize"))
        for text in ["true", "YES", "on", "1", "True"] {
            var config = makeConfiguration()
            config.displayAutoResizes = false
            try write(key, text, to: &config)
            #expect(config.displayAutoResizes, "\(text)")
        }
        for text in ["false", "NO", "off", "0"] {
            var config = makeConfiguration()
            config.displayAutoResizes = true
            try write(key, text, to: &config)
            #expect(!config.displayAutoResizes, "\(text)")
        }
        var config = makeConfiguration()
        config.displayAutoResizes = true
        #expect(read(key, config) == "true")
        config.displayAutoResizes = false
        #expect(read(key, config) == "false")
    }

    @Test("System keys takes and reads back every mode, live")
    func systemKeysTakesEveryMode() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "input.systemKeys"))
        #expect(VMGuestOS.allCases.allSatisfy { key.gate($0) == .live })

        for mode in VMSystemKeyForwarding.allCases {
            var config = makeConfiguration()
            try write(key, mode.rawValue, to: &config)
            #expect(config.systemKeyForwarding == mode)
            #expect(read(key, config) == mode.rawValue)
        }
    }

    @Test("A value outside a key's range is refused rather than clamped")
    func outOfRangeValuesAreRefused() throws {
        let original = makeConfiguration()
        let cases: [(key: String, value: String)] = [
            ("cpus", String(VMResourceLimits.cpuCount.lower - 1)),
            ("cpus", String(VMResourceLimits.cpuCount.upper + 1)),
            ("cpus", "four"),
            ("memory", "0"),
            ("memory", VMResourceLimits.memorySize.upper.adding(gibibytes: 1).gibibytesText),
            ("memory", "lots"),
            ("display.width", "0"),
            ("display.width", String(original.displayBaseSizeBounds.upper + 1)),
            ("display.height", "0"),
            ("display.autoResize", "maybe"),
            ("display.preference", "windowed"),
            ("input.systemKeys", "sometimes"),
            ("network.mode", "nat"),
            ("network.mac", "aa-bb-cc-dd-ee-ff"),
            ("network.mac", "00:00:00:00:00:00"),
        ]
        for entry in cases {
            let key = try #require(VMConfigurationKeyRegistry.key(named: entry.key))
            var config = original
            #expect(throws: CommandError.self, "\(entry)") {
                try write(key, entry.value, to: &config)
            }
            #expect(config == original, "\(entry)")
        }
    }

    @Test("An unparseable value refuses as an argument, never as a failed operation")
    func valueRefusalsAreArgumentRefusals() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "cpus"))
        var config = makeConfiguration()
        do {
            try write(key, "999", to: &config)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .invalidArgument(let message) = error else {
                Issue.record("expected invalidArgument, got \(error)")
                return
            }
            #expect(message.contains("cpus"))
        }
    }

    // MARK: - Display

    @Test("Turning HiDPI on rewrites the boot resolution the settings pane does")
    func hiDPIRewritesTheResolution() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "display.hidpi"))
        var config = makeConfiguration()
        config.displayResolution = DisplayBootSizing.Resolution(
            width: 1920, height: 1200, ppi: DisplayBootSizing.standardPixelsPerInch)
        config.displayHiDPI = false

        try write(key, "true", to: &config)

        #expect(config.displayHiDPI)
        #expect(config.displayWidth == 3840)
        #expect(config.displayHeight == 2400)
        #expect(config.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
    }

    @Test("A guest with no display density is not offered HiDPI at all")
    func linuxGuestsHaveNoHiDPIKey() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "display.hidpi"))
        #expect(!key.applies(makeConfiguration(guestOS: .linux)))
        #expect(key.applies(makeConfiguration(guestOS: .macOS)))
    }

    @Test("Leaving size-to-window promotes the stored trio to the chosen density")
    func leavingSizeToWindowCarriesTheDensity() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "display.sizeToWindow"))
        var config = makeConfiguration()
        config.displaySizesToWindow = true
        config.displayHiDPI = true
        config.displayResolution = DisplayBootSizing.Resolution(
            width: 1920, height: 1200, ppi: DisplayBootSizing.standardPixelsPerInch)

        try write(key, "false", to: &config)

        #expect(!config.displaySizesToWindow)
        #expect(config.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
        #expect(config.displayWidth == 3840)
    }

    @Test("The size keys read and write the size the settings pane's fields show")
    func sizeKeysSpeakBaseSize() throws {
        let width = try #require(VMConfigurationKeyRegistry.key(named: "display.width"))
        let height = try #require(VMConfigurationKeyRegistry.key(named: "display.height"))
        var config = makeConfiguration()

        #expect(read(width, config) == "1920")
        #expect(read(height, config) == "1200")

        try write(width, "1280", to: &config)
        try write(height, "800", to: &config)

        // The pane's own Width/Height write, arrived at through the one helper
        // both call: doubled for the density, and never below the minimum.
        #expect(config.displayWidth == 2560)
        #expect(config.displayHeight == 1600)
        #expect(config.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
    }

    @Test("A size key takes any size down to 1 and sets no maximum of its own")
    func sizeKeysTakeTheFrameworksBounds() throws {
        let width = try #require(VMConfigurationKeyRegistry.key(named: "display.width"))
        var config = makeConfiguration()

        try write(width, "1", to: &config)
        #expect(config.displayWidth == 2)

        try write(width, "20000", to: &config)
        #expect(config.displayWidth == 40000)

        var standard = makeConfiguration(guestOS: .linux)
        try write(width, "1", to: &standard)
        #expect(standard.displayWidth == 1)
        try write(width, "20000", to: &standard)
        #expect(standard.displayWidth == 20000)
    }

    // MARK: - Resources

    @Test("Memory takes decimal gigabytes to the nearest megabyte and reads them back")
    func memoryTakesDecimalGigabytes() throws {
        let memory = try #require(VMConfigurationKeyRegistry.key(named: "memory"))
        var config = makeConfiguration()

        try write(memory, "1.5", to: &config)
        #expect(config.memorySizeInGB.mebibytes == 1536)
        #expect(read(memory, config) == "1.5")

        try write(memory, "2", to: &config)
        #expect(config.memorySizeInGB == .gibibytes(2))
        #expect(read(memory, config) == "2")
    }

    @Test("A size key states its refusal while the display is sized to its window")
    func sizeKeysRefuseUnderSizeToWindow() throws {
        let width = try #require(VMConfigurationKeyRegistry.key(named: "display.width"))
        var config = makeConfiguration()
        #expect(resultRefusal(width, on: config) == nil)

        config.displaySizesToWindow = true
        let refusal = try #require(resultRefusal(width, on: config))
        #expect(refusal.contains("display.sizeToWindow"))
    }

    // MARK: - Network

    @Test("The mode key spells no device as none, both ways")
    func modeKeySpellsNoDeviceAsNone() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "network.mode"))
        var config = makeConfiguration()
        #expect(read(key, config) == "shared")

        try write(key, "none", to: &config)
        #expect(!config.networkEnabled)
        #expect(read(key, config) == "none")
        // The mode is remembered, so coming back lands where the VM left.
        #expect(config.networkMode == .shared)

        try write(key, "hostOnly", to: &config)
        #expect(config.networkEnabled)
        #expect(config.networkMode == .hostOnly)
    }

    @Test("A VM given a network device is given an address with it")
    func enablingTheDeviceMintsAnAddress() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "network.mode"))
        var config = makeConfiguration()
        config.networkEnabled = false
        config.macAddress = nil

        try write(key, "shared", to: &config)

        let minted = try #require(config.macAddress)
        #expect(GuestMACAddress.normalized(minted) == minted)
    }

    @Test("network.membership round-trips, hot-swaps with the attachment, and refuses another value")
    func membershipKeyRoundTrips() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "network.membership"))
        var config = makeConfiguration()
        #expect(read(key, config) == "common")

        try write(key, "isolated", to: &config)
        #expect(config.networkMembership == .isolated)
        #expect(read(key, config) == "isolated")
        #expect(key.capability(writing: "common", for: .linux) == .switchNetworkMembership)
        #expect(throws: CommandError.self) { try write(key, "true", to: &config) }
    }

    @Test("network.membership names a listed network by name or identifier, and reads back its identifier")
    func membershipNamesANamedNetwork() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "network.membership"))
        guard case .configuration(let field) = key.field else {
            Issue.record("not a configuration key")
            return
        }
        let lab = VMNamedNetwork(id: UUID(), name: "Lab", kind: .shared)
        let listing = context(networks: [lab])
        var config = makeConfiguration()

        try field.write("lab", &config, listing)
        #expect(config.networkMembership == .network(lab.id))
        #expect(read(key, config) == lab.id.uuidString)
        #expect(config.joinedNetwork == .vmnet(VmnetNetworkID(kind: .shared, scope: .named(lab.id))))
        #expect(field.refusalOnResult(config, listing) == nil)

        // What a read answered is taken back.
        var again = makeConfiguration()
        try field.write(read(key, config), &again, listing)
        #expect(again.networkMembership == config.networkMembership)
        #expect(throws: CommandError.self) { try field.write("Office", &config, listing) }
    }

    @Test("A VM joins a named network only in the network's mode, and only one the library lists")
    func namedNetworkMembershipIsJudgedOnTheResult() throws {
        let membership = try #require(VMConfigurationKeyRegistry.key(named: "network.membership"))
        let mode = try #require(VMConfigurationKeyRegistry.key(named: "network.mode"))
        guard case .configuration(let membershipField) = membership.field,
            case .configuration(let modeField) = mode.field
        else {
            Issue.record("not configuration keys")
            return
        }
        let lab = VMNamedNetwork(id: UUID(), name: "Lab", kind: .hostOnly)
        let listing = context(networks: [lab])

        // Shared VM onto a Host Only network: refused until the mode follows.
        var config = makeConfiguration()
        try membershipField.write("Lab", &config, listing)
        #expect(membershipField.refusalOnResult(config, listing)?.contains("hostOnly") == true)
        try modeField.write("hostOnly", &config, listing)
        #expect(membershipField.refusalOnResult(config, listing) == nil)
        #expect(modeField.refusalOnResult(config, listing) == nil)

        // The network leaving the library leaves the VM on an unlisted one,
        // which a write onto it refuses.
        #expect(membershipField.refusalOnResult(config, context()) != nil)

        // Bridged and no device make the membership inert.
        try modeField.write("bridged", &config, listing)
        #expect(modeField.refusalOnResult(config, listing) == nil)
    }

    @Test("A build without VM networking refuses a write onto a network it cannot attach, naming the build")
    func unattachableNetworksAreRefusedWhereEntered() throws {
        let mode = try #require(VMConfigurationKeyRegistry.key(named: "network.mode"))
        let membership = try #require(VMConfigurationKeyRegistry.key(named: "network.membership"))
        let unentitled = context(entitlements: .unentitled)
        func refusal(_ key: VMConfigurationKey, _ value: String, on config: VMConfiguration) -> CommandError? {
            var settings = VMSettings(configuration: config, hostState: VMHostState())
            do {
                try key.apply(value, to: &settings, context: unentitled)
                return nil
            } catch let error as CommandError {
                return error
            } catch {
                Issue.record("Unexpected error \(error)")
                return nil
            }
        }
        let shared = makeConfiguration()

        #expect(refusal(mode, "hostOnly", on: shared) == .unsupportedByBuild(capability: "host-only networking"))
        #expect(refusal(mode, "bridged", on: shared) == .unsupportedByBuild(capability: "bridged networking"))
        #expect(
            refusal(membership, "isolated", on: shared)
                == .unsupportedByBuild(capability: "isolating a virtual machine from other virtual machines"))
        #expect(refusal(mode, "shared", on: shared) == nil)
        #expect(refusal(membership, "common", on: shared) == nil)
        #expect(
            !mode.accepts(
                "hostOnly", settings: VMSettings(configuration: shared, hostState: VMHostState()), context: unentitled))

        // A VM that arrived on such a network can be moved off it, and writing
        // back what it holds is no move at all.
        var hostOnly = shared
        hostOnly.networkMode = .hostOnly
        #expect(refusal(mode, "shared", on: hostOnly) == nil)
        #expect(refusal(mode, "hostOnly", on: hostOnly) == nil)

        // The same writes land in a build that can attach them.
        var settings = VMSettings(configuration: shared, hostState: VMHostState())
        try mode.apply("hostOnly", to: &settings, context: context())
        try membership.apply("isolated", to: &settings, context: context())
        #expect(settings.configuration.joinsOwnNetwork)
    }

    @Test("An empty bridged interface is automatic, and an empty MAC removes it")
    func emptyValuesClearTheirFields() throws {
        let bridged = try #require(
            VMConfigurationKeyRegistry.key(named: "network.bridgedInterface"))
        var config = makeConfiguration()
        config.bridgedInterfaceIdentifier = "en1"
        try write(bridged, "", to: &config)
        #expect(config.bridgedInterfaceIdentifier == nil)
        #expect(read(bridged, config).isEmpty)

        let mac = try #require(VMConfigurationKeyRegistry.key(named: "network.mac"))
        try write(mac, "", to: &config)
        #expect(config.macAddress == nil)
    }

    @Test("Clearing the address is refused while the guest still has a device")
    func emptyMACStandsOnlyWithoutADevice() throws {
        let mac = try #require(VMConfigurationKeyRegistry.key(named: "network.mac"))
        var config = makeConfiguration()
        #expect(resultRefusal(mac, on: config) == nil)

        try write(mac, "", to: &config)
        // The write itself lands; what refuses it is the result, so taking the
        // device away in the same call leaves the empty spelling valid.
        let refusal = try #require(resultRefusal(mac, on: config))
        #expect(refusal.contains("network.mac"))

        config.applyNetworkMode(nil)
        #expect(resultRefusal(mac, on: config) == nil)
    }

    @Test("A MAC address is stored in the one canonical spelling")
    func macAddressIsNormalized() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "network.mac"))
        var config = makeConfiguration()
        try write(key, " AA:BB:CC:DD:EE:F1\n", to: &config)
        #expect(config.macAddress == "aa:bb:cc:dd:ee:f1")
    }

    // MARK: - Ephemeral

    @Test("Ephemeral Mode pins the baseline the settings pane would")
    func ephemeralPinsTheSharedBaseline() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "ephemeral"))
        let manifest = makeManifest()
        var settings = VMSettings(configuration: makeConfiguration(), hostState: VMHostState())

        try write(key, "true", to: &settings, manifest: manifest)

        #expect(settings.hostState.ephemeralModeEnabled)
        #expect(settings.hostState.ephemeralBaselineSnapshotID == manifest.currentID)

        try write(key, "false", to: &settings, manifest: manifest)
        #expect(!settings.hostState.ephemeralModeEnabled)
        // Turning the mode off clears the choice rather than leaving a baseline
        // recorded against a mode nothing reads.
        #expect(settings.hostState.ephemeralBaselineSnapshotID == nil)
    }

    @Test("A VM with no snapshot cannot be made ephemeral")
    func ephemeralNeedsASnapshot() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "ephemeral"))
        var settings = VMSettings(configuration: makeConfiguration(), hostState: VMHostState())

        #expect(throws: CommandError.self) {
            try write(key, "true", to: &settings, manifest: VMSnapshotManifest())
        }
        #expect(!settings.hostState.ephemeralModeEnabled)
    }

    // MARK: - Host state

    @Test("A host-state key writes the host state and leaves the configuration alone")
    func hostStateKeysWriteTheHostState() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "display.preference"))
        let original = VMSettings(configuration: makeConfiguration(), hostState: VMHostState())
        var settings = original

        try write(key, "popOut", to: &settings)

        #expect(settings.hostState.displayPreference == .popOut)
        #expect(settings.configuration == original.configuration)
        #expect(key.read(settings) == "popOut")
    }

    // MARK: - Keys the settings panes write

    @Test("The keys the settings panes gained write the fields the panes did")
    func newKeysWriteTheFieldsThePaneDid() throws {
        typealias Keys = VMConfigurationKeyRegistry
        var settings = VMSettings(configuration: makeConfiguration(), hostState: VMHostState())
        let original = settings

        try write(Keys.audioInput, "true", to: &settings)
        try write(Keys.audioOutput, "false", to: &settings)
        try write(Keys.inputDevices, "usb", to: &settings)
        try write(Keys.serialSocket, "true", to: &settings)
        try write(Keys.agentLogForwarding, "true", to: &settings)
        try write(Keys.dropFiles, "false", to: &settings)
        try write(Keys.autoStart, "true", to: &settings)
        try write(Keys.agentInstallReminder, "false", to: &settings)

        var expected = original
        expected.configuration.audioInputEnabled = true
        expected.configuration.audioOutputEnabled = false
        expected.configuration.inputDeviceMode = .usb
        expected.configuration.serialSocketRelayEnabled = true
        expected.configuration.agentLogForwardingEnabled = true
        expected.configuration.dropFilesEnabled = false
        expected.hostState.startsAutomaticallyOnLaunch = true
        // The key names the reminder; the stored flag names its dismissal.
        expected.hostState.agentInstallNudgeDismissed = true
        #expect(settings == expected)
        #expect(Keys.agentInstallReminder.read(settings) == "false")
    }

    @Test("The guest-agent and input-device keys apply to macOS guests only")
    func agentKeysApplyToMacOSOnly() {
        typealias Keys = VMConfigurationKeyRegistry
        let linux = makeConfiguration(guestOS: .linux)
        let macOS = makeConfiguration(guestOS: .macOS)
        for key in [
            Keys.inputDevices, Keys.dropFiles, Keys.agentLogForwarding, Keys.agentInstallReminder,
        ] {
            #expect(!key.applies(linux), "\(key.name)")
            #expect(key.applies(macOS), "\(key.name)")
        }
    }

    @Test("A baseline named by identifier or by name turns the mode on with that snapshot")
    func ephemeralBaselinePicksASnapshotAndTurnsTheModeOn() throws {
        let key = VMConfigurationKeyRegistry.ephemeralBaseline
        let older = VMSnapshot(
            name: "Clean", createdAt: Date(timeIntervalSince1970: 1), kind: .cold, macAddress: nil)
        let newer = VMSnapshot(
            name: "Configured", createdAt: Date(timeIntervalSince1970: 2), kind: .warm,
            macAddress: nil)
        let manifest = VMSnapshotManifest(snapshots: [older, newer], currentID: older.id)
        var settings = VMSettings(configuration: makeConfiguration(), hostState: VMHostState())
        #expect(key.read(settings) == "")

        try write(key, newer.id.uuidString, to: &settings, manifest: manifest)
        #expect(settings.hostState.ephemeralModeEnabled)
        #expect(settings.hostState.ephemeralBaselineSnapshotID == newer.id)
        #expect(key.read(settings) == newer.id.uuidString)

        // Matched the way the snapshot verbs match a typed name: case aside.
        try write(key, "clean", to: &settings, manifest: manifest)
        #expect(settings.hostState.ephemeralBaselineSnapshotID == older.id)
    }

    @Test("A baseline the VM has no snapshot for is refused, and an empty one changes nothing")
    func ephemeralBaselineRefusesASnapshotTheVMLacks() throws {
        let key = VMConfigurationKeyRegistry.ephemeralBaseline
        let manifest = makeManifest()
        let original = VMSettings(configuration: makeConfiguration(), hostState: VMHostState())
        var settings = original

        #expect(throws: CommandError.self) {
            try write(key, UUID().uuidString, to: &settings, manifest: manifest)
        }
        #expect(throws: CommandError.self) {
            try write(key, "Nothing by this name", to: &settings, manifest: manifest)
        }
        #expect(settings == original)

        try write(key, "", to: &settings, manifest: manifest)
        #expect(settings == original)
    }

    @Test("A snapshot name two snapshots share is refused rather than guessed")
    func ephemeralBaselineRefusesAnAmbiguousName() throws {
        let key = VMConfigurationKeyRegistry.ephemeralBaseline
        let first = VMSnapshot(
            name: "Twin", createdAt: Date(timeIntervalSince1970: 1), kind: .cold, macAddress: nil)
        let second = VMSnapshot(
            name: "Twin", createdAt: Date(timeIntervalSince1970: 2), kind: .cold, macAddress: nil)
        let manifest = VMSnapshotManifest(snapshots: [first, second], currentID: first.id)
        var settings = VMSettings(configuration: makeConfiguration(), hostState: VMHostState())

        #expect(throws: CommandError.self) {
            try write(key, "Twin", to: &settings, manifest: manifest)
        }
        #expect(!settings.hostState.ephemeralModeEnabled)
    }

    // MARK: - accepts

    @Test("accepts answers what a write would refuse, and writes nothing")
    func acceptsAnswersWhatAWriteWouldRefuse() {
        typealias Keys = VMConfigurationKeyRegistry
        var config = makeConfiguration()
        config.clipboardSharingEnabled = false
        let settings = VMSettings(configuration: config, hostState: VMHostState())
        let withSnapshot = context()
        let withoutSnapshot = context(VMSnapshotManifest())

        // The key's own parsing.
        #expect(!Keys.cpus.accepts("many", settings: settings, context: withSnapshot))
        #expect(Keys.cpus.accepts(String(config.cpuCount), settings: settings, context: withSnapshot))
        // The key's own refusal.
        #expect(!Keys.ephemeral.accepts("true", settings: settings, context: withoutSnapshot))
        #expect(Keys.ephemeral.accepts("true", settings: settings, context: withSnapshot))
        #expect(Keys.ephemeral.accepts("false", settings: settings, context: withoutSnapshot))
        // The whole-result refusal, asked only of a value that moves.
        #expect(!Keys.clipboardPassthrough.accepts("true", settings: settings, context: withSnapshot))
        var inert = settings
        inert.configuration.clipboardPassthroughEnabled = true
        #expect(Keys.clipboardPassthrough.accepts("false", settings: inert, context: withSnapshot))
        #expect(Keys.clipboardPassthrough.accepts("true", settings: inert, context: withSnapshot))
        // A key the guest cannot have.
        let linux = VMSettings(configuration: makeConfiguration(guestOS: .linux), hostState: VMHostState())
        #expect(!Keys.dropFiles.accepts("true", settings: linux, context: withSnapshot))
    }
}
