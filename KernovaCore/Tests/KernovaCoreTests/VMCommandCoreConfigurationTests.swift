import CoreGraphics
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The configuration verbs against a real library: the keyspace read and
/// written through the core's own gates, the shared-directory edits a caller
/// names by path, and every refusal each of them owes.
@Suite("VMCommandCore Configuration Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreConfigurationTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMCommandCoreConfigurationTests")

    private func makeHarness(entitlements: EntitlementService = .entitled) -> WiredCommandCore {
        WiredCommandCore(entitlements: entitlements, preferences: preferences)
    }

    /// A folder that really is one, so the share verb's directory check passes.
    private func makeFolder(_ name: String) throws -> URL {
        let url = scratch.url.appendingPathComponent(
            "kernova-share-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeInstance(
        in harness: WiredCommandCore, name: String = "Alpha", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux, snapshots: [VMSnapshot] = [],
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots,
            library: harness.library, preferences: preferences,
            mutate: mutate)
    }

    private func value(_ entries: [ConfigurationEntry], _ key: String) throws -> String {
        try #require(entries.first { $0.key == key }?.value, "no \(key)")
    }

    // MARK: - Keys

    @Test("The keyspace listing is the registry, in its own order")
    func keysAreTheRegistry() {
        let harness = makeHarness()
        let descriptors = harness.core.configurationKeys()

        #expect(descriptors.map(\.name) == VMConfigurationKeyRegistry.keys.map(\.name))
        #expect(
            descriptors.contains {
                $0.name == "cpus" && $0.editableWhileRunning == ["macOS": false, "linux": false]
            })
        #expect(
            descriptors.contains {
                $0.name == "ephemeral" && $0.editableWhileRunning == ["macOS": true, "linux": true]
            })
        // The listing is the whole documentation of what a key takes, so a key
        // reaching it without a summary is a key nobody can set.
        for descriptor in descriptors {
            #expect(!descriptor.summary.isEmpty, "\(descriptor.name) has no summary")
        }
    }

    // MARK: - Read

    @Test("A key the guest cannot have is refused when it is named outright")
    func namedReadRefusesAnInapplicableKey() throws {
        let harness = makeHarness()
        makeInstance(in: harness, guestOS: .linux)

        let error = try #require(throws: CommandError.self) {
            _ = try harness.core.configuration(.name("Alpha"), keys: ["display.hidpi"])
        }
        guard case .unsupported = error else {
            Issue.record("expected unsupported, got \(error)")
            return
        }
    }

    // MARK: - Write

    @Test("A set onto a network this build cannot attach is refused naming the build, and writes nothing")
    func setOntoAnUnattachableNetworkIsRefused() throws {
        let harness = makeHarness(entitlements: .unentitled)
        let instance = makeInstance(in: harness) { $0.applyNetworkMode(.nat) }
        let before = instance.configuration

        for (key, value, capability) in [
            ("network.mode", "hostOnly", "host-only networking"),
            ("network.mode", "bridged", "bridged networking"),
            ("network.membership", "isolated", "isolating a virtual machine from other virtual machines"),
        ] {
            #expect(throws: CommandError.unsupportedByBuild(capability: capability)) {
                try harness.core.setConfiguration(
                    .name("Alpha"), assignments: [ConfigurationEntry(key: key, value: value)],
                    consent: .none)
            }
        }
        // The wire states the refusal as the build's.
        #expect(
            CommandError.unsupportedByBuild(capability: "host-only networking").dto.message
                == "This build of Kernova does not support host-only networking.")
        #expect(instance.configuration == before)
        #expect(harness.storage.bundles[instance.bundleURL] == before)
    }

    @Test("A set keeps what another copy wrote to the bundle since this one read it")
    func setKeepsFieldsChangedOnDiskSinceLoad() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        // Another Kernova copy changed memory and the display preference after
        // this one read the bundle.
        var onDisk = instance.configuration
        onDisk.memorySizeInGB = onDisk.memorySizeInGB.adding(gibibytes: 2)
        harness.storage.files.setConfiguration(onDisk, at: instance.bundleURL)
        var hostStateOnDisk = instance.hostState
        hostStateOnDisk.displayPreference = .fullscreen
        harness.storage.files.setHostState(hostStateOnDisk, at: instance.bundleURL)

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "display.autoResize", value: "false")],
            consent: .none)

        let configuration = try #require(harness.storage.bundles[instance.bundleURL])
        #expect(configuration.memorySizeInGB == onDisk.memorySizeInGB)
        #expect(!configuration.displayAutoResizes)
        #expect(harness.storage.hostStates[instance.bundleURL]?.displayPreference == .fullscreen)
        #expect(instance.configuration == configuration)
        #expect(instance.hostState == harness.storage.hostStates[instance.bundleURL])
    }

    @Test("A Retina display's odd size reads back as a set that changes nothing")
    func anOddRetinaSizeRoundTrips() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, guestOS: .macOS) {
            $0.displayResolution = DisplayBootSizing.Resolution(
                width: 1602, height: 1202, ppi: DisplayBootSizing.hiDPIPixelsPerInch)
            $0.displaySizesToWindow = false
            $0.displayHiDPI = true
        }
        let before = instance.configuration
        let onDisk = harness.storage.bundles[instance.bundleURL]

        let read = try harness.core.configuration(
            .name("Alpha"), keys: ["display.width", "display.height"])
        #expect(read.map(\.value) == ["801", "601"])
        try harness.core.setConfiguration(.name("Alpha"), assignments: read, consent: .none)

        #expect(instance.configuration == before)
        #expect(harness.storage.bundles[instance.bundleURL] == onDisk)
    }

    @Test("The smallest size a Retina window fit stores reads back as a set that changes nothing")
    func theSmallestRetinaFitRoundTrips() throws {
        let harness = makeHarness()
        let smallest = DisplayBootSizing.resolution(fittingPoints: .zero, backingScaleFactor: 2)
        let instance = makeInstance(in: harness, guestOS: .macOS) {
            $0.displayResolution = smallest
            $0.displaySizesToWindow = true
            $0.displayHiDPI = true
        }
        let before = instance.configuration
        let onDisk = harness.storage.bundles[instance.bundleURL]

        let read = try harness.core.configuration(.name("Alpha"), keys: nil)
        #expect(read.contains(ConfigurationEntry(key: "display.width", value: String(smallest.width / 2))))
        try harness.core.setConfiguration(.name("Alpha"), assignments: read, consent: .none)

        #expect(instance.configuration == before)
        #expect(harness.storage.bundles[instance.bundleURL] == onDisk)
    }

    @Test("A running VM still takes the settings read at other moments than boot")
    func liveKeysAreWritableWhileRunning() throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS)

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "clipboard.sharing", value: "true"),
                ConfigurationEntry(key: "display.autoResize", value: "false"),
                ConfigurationEntry(key: "input.systemKeys", value: "fullscreenOnly"),
            ],
            consent: .none)

        #expect(instance.configuration.clipboardSharingEnabled)
        #expect(!instance.configuration.displayAutoResizes)
        #expect(instance.configuration.systemKeyForwarding == .fullscreenOnly)
    }

    @Test("A running VM refuses the new machine keys, naming each one it refused")
    func runningVMRefusesTheNewMachineKeys() throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS)
        let before = instance.configuration
        let onDisk = harness.storage.bundles[instance.bundleURL]
        let moved = [
            ConfigurationEntry(key: "audio.input", value: String(!before.audioInputEnabled)),
            ConfigurationEntry(key: "audio.output", value: String(!before.audioOutputEnabled)),
            ConfigurationEntry(
                key: "input.devices",
                value: before.inputDeviceMode == .usb ? "mac" : "usb"),
        ]

        for assignment in moved {
            let error = try #require(throws: CommandError.self, "expected a refusal of \(assignment.key)") {
                try harness.core.setConfiguration(
                    .name("Alpha"), assignments: [assignment], consent: .none)
            }
            guard case .invalidState(_, _, _, let settings) = error else {
                Issue.record("expected invalidState, got \(error)")
                continue
            }
            #expect(settings == [assignment])
            #expect(error.message.contains(assignment.key))
        }

        let error = try #require(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: moved + [ConfigurationEntry(key: "serial.socket", value: "true")],
                consent: .none)
        }
        guard case .invalidState(_, _, _, let settings) = error else {
            Issue.record("expected invalidState, got \(error)")
            return
        }
        // The live key in the batch is not what the state refused.
        #expect(settings == moved)
        #expect(instance.configuration == before)
        #expect(harness.storage.bundles[instance.bundleURL] == onDisk)
    }

    @Test("A running VM takes the new live keys")
    func runningVMTakesTheNewLiveKeys() throws {
        let harness = makeHarness()
        let snapshot = VMSnapshot(
            name: "Clean", createdAt: Date(timeIntervalSince1970: 1), kind: .cold,
            macAddress: nil)
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS,
            snapshots: [snapshot])
        let before = instance.settings

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(
                    key: "serial.socket", value: String(!before.configuration.serialSocketRelayEnabled)),
                ConfigurationEntry(
                    key: "agent.logForwarding",
                    value: String(!before.configuration.agentLogForwardingEnabled)),
                ConfigurationEntry(
                    key: "dropFiles", value: String(!before.configuration.dropFilesEnabled)),
                ConfigurationEntry(
                    key: "autoStart", value: String(!before.hostState.startsAutomaticallyOnLaunch)),
                ConfigurationEntry(
                    key: "agent.installReminder",
                    value: String(before.hostState.agentInstallNudgeDismissed)),
                ConfigurationEntry(key: "ephemeral.baseline", value: "Clean"),
            ],
            consent: Consent([.setEphemeralBaseline]))

        let after = instance.settings
        #expect(after.configuration.serialSocketRelayEnabled != before.configuration.serialSocketRelayEnabled)
        #expect(
            after.configuration.agentLogForwardingEnabled
                != before.configuration.agentLogForwardingEnabled)
        #expect(after.configuration.dropFilesEnabled != before.configuration.dropFilesEnabled)
        #expect(
            after.hostState.startsAutomaticallyOnLaunch
                != before.hostState.startsAutomaticallyOnLaunch)
        #expect(
            after.hostState.agentInstallNudgeDismissed
                != before.hostState.agentInstallNudgeDismissed)
        #expect(after.hostState.ephemeralModeEnabled)
        #expect(after.hostState.ephemeralBaselineSnapshotID == snapshot.id)
    }

    @Test("A running networked VM hot-swaps its mode but cannot lose its device")
    func networkModeIsLiveSwitchableButNotRemovable() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .nat
        }

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "network.mode", value: "hostOnly")],
            consent: .none)
        #expect(instance.configuration.networkMode == .hostOnly)

        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "network.mode", value: "none")],
                consent: .none)
        }
        #expect(instance.configuration.networkEnabled)
    }

    @Test("network.mac=new lands a fresh unicast address, which a read answers in place of new")
    func newMACAddressIsMinted() throws {
        let harness = makeHarness()
        let old = "02:00:00:00:00:01"
        let instance = makeInstance(in: harness) { $0.macAddress = old }
        let key = VMConfigurationKeyRegistry.networkMAC

        let answered = try harness.core.setConfiguration(
            .name("Alpha"), assignments: [key.assigning(" NEW ")], consent: .none)

        let minted = try #require(instance.configuration.macAddress)
        #expect(minted != old)
        #expect(GuestMACAddress.normalized(minted) == minted)
        #expect(try value(answered, key.name) == minted)
        #expect(
            try value(try harness.core.configuration(.name("Alpha"), keys: [key.name]), key.name) == minted)
        #expect(
            key.accepts(VMConfigurationKeyRegistry.newMACAddressValue, for: instance, in: harness.library))
    }

    @Test("Passthrough refuses without sharing, whichever order the pair arrives in")
    func passthroughNeedsSharing() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, guestOS: .macOS)

        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "clipboard.passthrough", value: "true")],
                consent: .all)
        }
        #expect(!instance.configuration.clipboardPassthroughEnabled)

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "clipboard.passthrough", value: "true"),
                ConfigurationEntry(key: "clipboard.sharing", value: "true"),
            ],
            consent: .all)
        #expect(instance.configuration.clipboardPassthroughEnabled)
        #expect(instance.configuration.clipboardSharingEnabled)
    }

    @Test("Turning sharing off leaves a passthrough flag already set alone")
    func turningSharingOffIsNotAPassthroughEnable() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, guestOS: .macOS) {
            $0.clipboardSharingEnabled = true
            $0.clipboardPassthroughEnabled = true
        }

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "clipboard.sharing", value: "false")],
            consent: .none)

        #expect(!instance.configuration.clipboardSharingEnabled)
        #expect(instance.configuration.clipboardPassthroughEnabled)
    }

    @Test("Every value a get answers is a value a set takes back")
    func readValuesAreWritableValues() throws {
        let harness = makeHarness()
        // A size named to the megabyte, so memory's decimal read is written back.
        let instance = makeInstance(in: harness) { $0.memorySizeInGB = VMMemorySize(mebibytes: 1537) }
        let before = instance.configuration

        let entries = try harness.core.configuration(.name("Alpha"), keys: nil)
        #expect(entries.contains(ConfigurationEntry(key: "memory", value: "1.501")))
        let answered = try harness.core.setConfiguration(
            .name("Alpha"), assignments: entries, consent: .none)

        #expect(instance.configuration == before)
        #expect(answered == entries)
    }

    @Test("Turning sharing on over a passthrough flag already set asks for consent")
    func sharingEnableOverAStalePassthroughFlagAsksForConsent() throws {
        let harness = makeHarness()
        // Reachable from both surfaces: passthrough is left set when sharing
        // goes off, and turning sharing back on starts it running again.
        let instance = makeInstance(in: harness, guestOS: .macOS) { $0.clipboardPassthroughEnabled = true }

        let error = try #require(throws: CommandError.self) {
            _ = try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "clipboard.sharing", value: "true")],
                consent: .none)
        }
        #expect(error.confirmationPrompt?.kind == .enableClipboardPassthrough)
        #expect(!instance.configuration.clipboardSharingEnabled)

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "clipboard.sharing", value: "true")],
            consent: .all)
        #expect(instance.configuration.clipboardPassthroughIsEffective)
    }

    // MARK: - Install reminder

    @Test(
        "While the install reminder is off for every VM, agent.installReminder refuses a move and takes its own value",
        arguments: [false, true])
    func installReminderRefusesAMoveWhileOffForAllVMs(dismissed: Bool) throws {
        let harness = makeHarness()
        preferences.agentInstallPromptDisabled = true
        let instance = makeInstance(in: harness, guestOS: .macOS)
        harness.library.editHostState(of: instance) { $0.agentInstallNudgeDismissed = dismissed }
        let key = VMConfigurationKeyRegistry.agentInstallReminder
        let held = String(!dismissed)
        let moved = String(dismissed)

        #expect(
            throws: CommandError.invalidArgument(
                "The guest agent install reminder is turned off for all virtual machines in Settings → Reminders. "
                    + "Turn it on there to change agent.installReminder.")
        ) {
            try harness.core.setConfiguration(
                .name("Alpha"), assignments: [key.assigning(moved)], consent: .none)
        }
        #expect(instance.hostState.agentInstallNudgeDismissed == dismissed)
        #expect(!harness.core.capabilities.isAvailable(key, writing: moved, on: instance))

        // `get` output stays valid `set` input.
        let read = try harness.core.configuration(.name("Alpha"), keys: [key.name])
        #expect(try value(read, key.name) == held)
        try harness.core.setConfiguration(.name("Alpha"), assignments: read, consent: .none)
        #expect(instance.hostState.agentInstallNudgeDismissed == dismissed)
        #expect(harness.core.capabilities.isAvailable(key, writing: held, on: instance))
    }

    @Test("With the install reminder on for every VM, agent.installReminder takes a move", arguments: [false, true])
    func installReminderTakesAMoveWhileOn(dismissed: Bool) throws {
        let harness = makeHarness()
        preferences.agentInstallPromptDisabled = false
        let instance = makeInstance(in: harness, guestOS: .macOS)
        harness.library.editHostState(of: instance) { $0.agentInstallNudgeDismissed = dismissed }
        let key = VMConfigurationKeyRegistry.agentInstallReminder
        #expect(harness.core.capabilities.isAvailable(key, writing: String(dismissed), on: instance))

        try harness.core.setConfiguration(
            .name("Alpha"), assignments: [key.assigning(dismissed)], consent: .none)

        #expect(instance.hostState.agentInstallNudgeDismissed == !dismissed)
    }

    // MARK: - Display size

    @Test("A width the new density would refuse lands whole when set before it")
    func displayWidthThenHiDPILandsWhole() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, guestOS: .macOS) {
            $0.displaySizesToWindow = false
            $0.displayHiDPI = false
            $0.displayResolution = DisplayBootSizing.Resolution(
                width: 1920, height: 1200, ppi: DisplayBootSizing.standardPixelsPerInch)
        }

        // The width is judged against the density it arrives under; the
        // density then rescales what landed. Each write runs once, so the
        // width is never judged a second time under the density that followed.
        let answered = try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "display.width", value: "6000"),
                ConfigurationEntry(key: "display.hidpi", value: "true"),
            ],
            consent: .none)

        let configuration = try #require(harness.storage.bundles[instance.bundleURL])
        #expect(configuration.displayHiDPI)
        #expect(instance.configuration == configuration)
        #expect(try value(answered, "display.hidpi") == "true")
        #expect(
            try value(answered, "display.width") == String(configuration.displayBaseSize.width))
    }

    // MARK: - MAC address

    @Test("A networked VM cannot be left with no address to send from")
    func emptyMACIsRefusedWhileTheDeviceIsThere() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "network.mode", value: "nat")],
            consent: .none)
        let before = instance.configuration
        #expect(before.macAddress != nil)

        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "network.mac", value: "")],
                consent: .none)
        }
        #expect(instance.configuration == before)

        // Taking the device away in the same call is what the empty spelling is
        // for, and the result is what decides — not the order.
        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "network.mac", value: ""),
                ConfigurationEntry(key: "network.mode", value: "none"),
            ],
            consent: .none)
        #expect(instance.configuration.macAddress == nil)
        #expect(!instance.configuration.networkEnabled)
    }

    @Test("A batch of configuration keys and a host-state key lands in both files")
    func aMixedBatchLandsInBothFiles() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness) {
            $0.networkEnabled = false
            $0.macAddress = nil
        }

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "network.mac", value: ""),
                ConfigurationEntry(key: "display.preference", value: "popOut"),
                ConfigurationEntry(key: "network.mode", value: "nat"),
                ConfigurationEntry(key: "cpus", value: "3"),
            ],
            consent: .none)

        let configuration = try #require(harness.storage.bundles[instance.bundleURL])
        #expect(configuration.networkEnabled)
        #expect(configuration.macAddress != nil)
        #expect(configuration.cpuCount == 3)
        #expect(harness.storage.hostStates[instance.bundleURL]?.displayPreference == .popOut)
        #expect(instance.configuration == configuration)
        #expect(instance.hostState == harness.storage.hostStates[instance.bundleURL])
    }

    // MARK: - Shared directories

    @Test("The share listing is what the VM carries, in order, without the bookmark behind it")
    func sharedDirectoriesAnswerWhatTheVMCarries() throws {
        let harness = makeHarness()
        makeInstance(in: harness) {
            $0.sharedDirectories = [
                SharedDirectory(
                    path: "/Users/somebody/Sites", readOnly: false, bookmark: Data([1, 2])),
                SharedDirectory(path: "/Users/somebody/Reference", readOnly: true),
            ]
        }

        let listed = try harness.core.sharedDirectories(of: .name("Alpha"))

        #expect(
            listed == [
                SharedDirectorySummary(path: "/Users/somebody/Sites", readOnly: false),
                SharedDirectorySummary(path: "/Users/somebody/Reference", readOnly: true),
            ])
    }

    @Test("A share is added by path, and adding the same folder again changes nothing")
    func addSharedDirectoryIsIdempotent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let folder = try makeFolder("sites")
        let path = folder.path(percentEncoded: false)

        try await harness.core.addSharedDirectory(.name("Alpha"), path: path, readOnly: true)
        #expect(instance.configuration.sharedDirectories?.count == 1)
        #expect(instance.configuration.sharedDirectories?.first?.readOnly == true)

        try await harness.core.addSharedDirectory(.name("Alpha"), path: path + "/", readOnly: false)
        #expect(instance.configuration.sharedDirectories?.count == 1)
        #expect(instance.configuration.sharedDirectories?.first?.readOnly == true)
        // The second call answered off the folder the VM already shares, so it
        // never went as far as asking for a grant.
        #expect(harness.authority.requests.count == 1)
    }

    @Test("A share is dropped by path, and a path the VM does not share refuses")
    func removeSharedDirectoryByPath() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let folder = try makeFolder("sites")
        let path = folder.path(percentEncoded: false)
        try await harness.core.addSharedDirectory(.name("Alpha"), path: path, readOnly: false)

        #expect(throws: CommandError.self) {
            try harness.core.removeSharedDirectory(.name("Alpha"), path: "/Users/somebody/Other")
        }
        #expect(instance.configuration.sharedDirectories?.count == 1)

        try harness.core.removeSharedDirectory(.name("Alpha"), path: path + "/")
        #expect(instance.configuration.sharedDirectories == nil)
    }

    @Test("A path naming anything but a folder is refused rather than stored")
    func shareAddRefusesANonDirectory() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("kernova-share.txt")
        try Data("not a folder".utf8).write(to: file)

        // The VM would refuse to start on a share naming a file, so the entry
        // is refused where it is entered.
        await #expect(throws: CommandError.self) {
            try await harness.core.addSharedDirectory(
                .name("Alpha"), path: file.path(percentEncoded: false), readOnly: false)
        }
        #expect(instance.configuration.sharedDirectories == nil)
    }

    @Test("Whatever the authority answers with is what gets shared")
    func shareAddSharesThePickedFolder() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let picked = try makeFolder("picked")
        harness.authority.substitute = picked

        try await harness.core.addSharedDirectory(
            .name("Alpha"), path: "/Users/somebody/Asked", readOnly: false)

        #expect(harness.authority.requests.map(\.source) == [.sharedDirectory])
        #expect(harness.authority.requestedURLs.map(\.path) == ["/Users/somebody/Asked"])
        #expect(
            instance.configuration.sharedDirectories?.map(\.path)
                == [picked.path(percentEncoded: false)])
    }
}
