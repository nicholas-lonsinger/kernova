import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

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
            cpuCount: guestOS.defaultCPUCount(within: FakeVirtualizationHost.resourceLimits),
            memorySizeInGB: guestOS.defaultMemorySize(within: FakeVirtualizationHost.resourceLimits),
            displayWidth: 3840, displayHeight: 2400,
            displayPPI: guestOS == .macOS
                ? DisplayBootSizing.hiDPIPixelsPerInch : DisplayBootSizing.standardPixelsPerInch,
            displaySizesToWindow: false, displayHiDPI: guestOS == .macOS,
            networkEnabled: true, networkMode: .nat, macAddress: "aa:bb:cc:dd:ee:ff")
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
            snapshots: manifest ?? makeManifest(), entitlements: entitlements, networks: .listed(networks),
            resourceLimits: FakeVirtualizationHost.resourceLimits,
            agentInstallReminder: AgentInstallReminder(isOffForAllVMs: false))
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

    @Test("The keyspace listing answers, per guest the key applies to, whether a running VM takes it")
    func descriptorsAnswerPerGuest() throws {
        func listing(_ name: String) throws -> [String: Bool] {
            let key = try #require(VMConfigurationKeyRegistry.key(named: name))
            #expect(key.descriptor.name == key.name)
            #expect(key.descriptor.summary == key.summary)
            return key.descriptor.editableWhileRunning
        }
        #expect(try listing("cpus") == ["macOS": false, "linux": false])
        #expect(try listing("clipboard.sharing") == ["macOS": true])
        #expect(try listing("network.mode") == ["macOS": true, "linux": true])
        #expect(try listing("ephemeral") == ["macOS": true, "linux": true])
        #expect(try listing("dropFiles") == ["macOS": true])
        for key in VMConfigurationKeyRegistry.keys { #expect(!key.summary.isEmpty) }
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

    // MARK: - Network

    @Test("The mode key spells no device as none, both ways")
    func modeKeySpellsNoDeviceAsNone() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "network.mode"))
        var config = makeConfiguration()
        #expect(read(key, config) == "nat")

        try write(key, "none", to: &config)
        #expect(!config.networkEnabled)
        #expect(read(key, config) == "none")
        // The mode is remembered, so coming back lands where the VM left.
        #expect(config.networkMode == .nat)

        try write(key, "hostOnly", to: &config)
        #expect(config.networkEnabled)
        #expect(config.networkMode == .hostOnly)
    }

    // MARK: - Keys the settings panes write

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
}
