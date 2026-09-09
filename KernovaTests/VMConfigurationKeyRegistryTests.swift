import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The `get`/`set` keyspace on its own: what each key reads, what it accepts,
/// and what it refuses — with no library, no VM and no wire in sight.
@Suite("VMConfigurationKeyRegistry Tests", .admissionGated)
@MainActor
struct VMConfigurationKeyRegistryTests {
    /// A macOS configuration in the shape every path in the app produces one:
    /// a network device with an address, a resolution the density agrees
    /// with, and resources inside this host's bounds, which CI runners set
    /// lower than a development Mac.
    private func makeConfiguration(guestOS: VMGuestOS = .macOS) -> VMConfiguration {
        var config = VMConfiguration(
            name: "Alpha", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi,
            cpuCount: guestOS.defaultCPUCount, memorySizeInGB: guestOS.defaultMemoryInGB,
            displayWidth: 3840, displayHeight: 2400,
            displayPPI: guestOS == .macOS
                ? DisplayBootSizing.hiDPIPixelsPerInch : DisplayBootSizing.standardPixelsPerInch,
            displaySizesToWindow: false, displayHiDPI: guestOS == .macOS,
            networkEnabled: true, networkMode: .shared, macAddress: "aa:bb:cc:dd:ee:ff")
        config.applyEphemeralMode(enabled: false, baseline: nil)
        return config
    }

    private func makeManifest() -> VMSnapshotManifest {
        let snapshot = VMSnapshot(
            name: "Baseline", createdAt: Date(timeIntervalSince1970: 1), kind: .cold)
        return VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id)
    }

    private func context(_ manifest: VMSnapshotManifest? = nil) -> VMConfigurationWriteContext {
        VMConfigurationWriteContext(snapshots: manifest ?? makeManifest())
    }

    private func write(
        _ key: VMConfigurationKey, _ value: String, to config: inout VMConfiguration,
        manifest: VMSnapshotManifest? = nil
    ) throws {
        try key.write(value, &config, context(manifest))
    }

    // MARK: - Round trip

    @Test("Every key writes back what it read without changing anything")
    func everyKeyRoundTrips() throws {
        for guestOS in VMGuestOS.allCases {
            let original = makeConfiguration(guestOS: guestOS)
            for key in VMConfigurationKeyRegistry.keys where key.applies(original) {
                var config = original
                try write(key, key.read(original), to: &config)
                #expect(config == original, "\(key.name) on \(guestOS.rawValue)")
            }
        }
    }

    @Test("Every key writes back what it read on a VM with no network device")
    func everyKeyRoundTripsWithoutANetworkDevice() throws {
        var original = makeConfiguration()
        original.networkEnabled = false
        original.macAddress = nil
        original.bridgedInterfaceIdentifier = nil

        for key in VMConfigurationKeyRegistry.keys where key.applies(original) {
            var config = original
            try write(key, key.read(original), to: &config)
            #expect(config == original, "\(key.name)")
        }
    }

    @Test("Every key writes back what it read on an ephemeral, sharing VM")
    func everyKeyRoundTripsWithEveryFlagOn() throws {
        let manifest = makeManifest()
        var original = makeConfiguration()
        original.applyEphemeralMode(
            enabled: true, baseline: manifest.defaultEphemeralBaseline(preferring: nil))
        original.clipboardSharingEnabled = true
        original.clipboardPassthroughEnabled = true
        original.displaySizesToWindow = true
        original.displayAutoResizes = false
        original.displayPreference = .fullscreen
        original.systemKeyForwarding = .fullscreenOnly
        original.networkMode = .bridged
        original.bridgedInterfaceIdentifier = "en1"

        for key in VMConfigurationKeyRegistry.keys where key.applies(original) {
            var config = original
            try write(key, key.read(original), to: &config, manifest: manifest)
            #expect(config == original, "\(key.name)")
        }
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

    @Test("A descriptor reports the key's own gate")
    func descriptorsReportTheGate() {
        for key in VMConfigurationKeyRegistry.keys {
            #expect(key.descriptor.name == key.name)
            #expect(key.descriptor.summary == key.summary)
            #expect(key.descriptor.editableWhileRunning == (key.gate != .atRest))
            #expect(!key.summary.isEmpty)
        }
    }

    @Test("Each gate names the capability that decides it")
    func gatesNameTheirCapability() throws {
        let cpus = try #require(VMConfigurationKeyRegistry.key(named: "cpus"))
        #expect(cpus.capability(writing: "4") == .editConfiguration)

        let ephemeral = try #require(VMConfigurationKeyRegistry.key(named: "ephemeral"))
        #expect(ephemeral.capability(writing: "true") == .editLiveConfiguration)

        let bridged = try #require(
            VMConfigurationKeyRegistry.key(named: "network.bridgedInterface"))
        #expect(bridged.capability(writing: "en0") == .switchNetworkMode)

        // A hot swap between attachable modes, but taking the device away is
        // not one — devices cannot be added or removed at runtime.
        let mode = try #require(VMConfigurationKeyRegistry.key(named: "network.mode"))
        #expect(mode.capability(writing: "bridged") == .switchNetworkMode)
        #expect(mode.capability(writing: "none") == .editConfiguration)
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
        #expect(key.read(config) == "true")
        config.displayAutoResizes = false
        #expect(key.read(config) == "false")
    }

    @Test("System keys takes and reads back every mode, live")
    func systemKeysTakesEveryMode() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "input.systemKeys"))
        #expect(key.gate == .live)

        for mode in VMSystemKeyForwarding.allCases {
            var config = makeConfiguration()
            try write(key, mode.rawValue, to: &config)
            #expect(config.systemKeyForwarding == mode)
            #expect(key.read(config) == mode.rawValue)
        }
    }

    @Test("A value outside a key's range is refused rather than clamped")
    func outOfRangeValuesAreRefused() throws {
        let original = makeConfiguration()
        let cases: [(key: String, value: String)] = [
            ("cpus", "1"),
            ("cpus", String(original.guestOS.maxCPUCount + 1)),
            ("cpus", "four"),
            ("memory", "1"),
            ("memory", String(original.guestOS.maxMemoryInGB + 1)),
            ("display.width", String(DisplayBootSizing.minimumWidth - 1)),
            ("display.width", String(DisplayBootSizing.maximumDimension + 1)),
            ("display.height", String(DisplayBootSizing.minimumHeight - 1)),
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

        #expect(width.read(config) == "1920")
        #expect(height.read(config) == "1200")

        try write(width, "1280", to: &config)
        try write(height, "800", to: &config)

        // The pane's own Width/Height write, arrived at through the one helper
        // both call: doubled for the density, and never below the minimum.
        #expect(config.displayWidth == 2560)
        #expect(config.displayHeight == 1600)
        #expect(config.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
    }

    @Test("A base size a HiDPI display cannot double is refused rather than clamped")
    func sizeKeysStopAtHalfTheCeiling() throws {
        let width = try #require(VMConfigurationKeyRegistry.key(named: "display.width"))
        var config = makeConfiguration()
        let before = config

        #expect(throws: CommandError.self) {
            try write(width, String(DisplayBootSizing.maximumDimension), to: &config)
        }
        #expect(config == before)

        // A 1× guest lays out in whole pixels, so the whole ceiling is its own.
        var standard = makeConfiguration(guestOS: .linux)
        try write(width, String(DisplayBootSizing.maximumDimension), to: &standard)
        #expect(standard.displayWidth == DisplayBootSizing.maximumDimension)
    }

    @Test("A size key states its refusal while the display is sized to its window")
    func sizeKeysRefuseUnderSizeToWindow() throws {
        let width = try #require(VMConfigurationKeyRegistry.key(named: "display.width"))
        var config = makeConfiguration()
        #expect(width.refusalOnResult(config) == nil)

        config.displaySizesToWindow = true
        let refusal = try #require(width.refusalOnResult(config))
        #expect(refusal.contains("display.sizeToWindow"))
    }

    // MARK: - Network

    @Test("The mode key spells no device as none, both ways")
    func modeKeySpellsNoDeviceAsNone() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "network.mode"))
        var config = makeConfiguration()
        #expect(key.read(config) == "shared")

        try write(key, "none", to: &config)
        #expect(!config.networkEnabled)
        #expect(key.read(config) == "none")
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

    @Test("An empty bridged interface is automatic, and an empty MAC removes it")
    func emptyValuesClearTheirFields() throws {
        let bridged = try #require(
            VMConfigurationKeyRegistry.key(named: "network.bridgedInterface"))
        var config = makeConfiguration()
        config.bridgedInterfaceIdentifier = "en1"
        try write(bridged, "", to: &config)
        #expect(config.bridgedInterfaceIdentifier == nil)
        #expect(bridged.read(config).isEmpty)

        let mac = try #require(VMConfigurationKeyRegistry.key(named: "network.mac"))
        try write(mac, "", to: &config)
        #expect(config.macAddress == nil)
    }

    @Test("Clearing the address is refused while the guest still has a device")
    func emptyMACStandsOnlyWithoutADevice() throws {
        let mac = try #require(VMConfigurationKeyRegistry.key(named: "network.mac"))
        var config = makeConfiguration()
        #expect(mac.refusalOnResult(config) == nil)

        try write(mac, "", to: &config)
        // The write itself lands; what refuses it is the result, so taking the
        // device away in the same call leaves the empty spelling valid.
        let refusal = try #require(mac.refusalOnResult(config))
        #expect(refusal.contains("network.mac"))

        config.applyNetworkMode(nil)
        #expect(mac.refusalOnResult(config) == nil)
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
        var config = makeConfiguration()

        try write(key, "true", to: &config, manifest: manifest)

        #expect(config.ephemeralModeEnabled)
        #expect(config.ephemeralBaselineSnapshotID == manifest.currentID)

        try write(key, "false", to: &config, manifest: manifest)
        #expect(!config.ephemeralModeEnabled)
        // Turning the mode off clears the choice rather than leaving a baseline
        // recorded against a mode nothing reads.
        #expect(config.ephemeralBaselineSnapshotID == nil)
    }

    @Test("A VM with no snapshot cannot be made ephemeral")
    func ephemeralNeedsASnapshot() throws {
        let key = try #require(VMConfigurationKeyRegistry.key(named: "ephemeral"))
        var config = makeConfiguration()

        #expect(throws: CommandError.self) {
            try write(key, "true", to: &config, manifest: VMSnapshotManifest())
        }
        #expect(!config.ephemeralModeEnabled)
    }
}
