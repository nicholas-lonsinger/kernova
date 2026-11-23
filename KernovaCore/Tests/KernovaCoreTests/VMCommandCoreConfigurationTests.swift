import CoreGraphics
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The configuration verbs against a real library: the keyspace read and
/// written through the core's own gates, and the refusals they owe.
@Suite("VMCommandCore Configuration Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreConfigurationTests {
    private let preferences = makeTestPreferences()

    private func makeHarness(entitlements: EntitlementService = .entitled) -> WiredCommandCore {
        WiredCommandCore(entitlements: entitlements, preferences: preferences)
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

    // MARK: - MAC address

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
}
