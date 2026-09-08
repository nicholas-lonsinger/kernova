import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The configuration verbs against a real library: the keyspace read and
/// written through the core's own gates, the shared-directory and
/// port-forwarding edits a caller names by path and by port, and every refusal
/// each of them owes.
@Suite("VMCommandCore Configuration Tests", .serialized, .admissionGated)
@MainActor
struct VMCommandCoreConfigurationTests {
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.commandconfig")

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let storage: MockVMStorageService
        let authority: MockSandboxSourceAuthority
    }

    private func makeHarness() -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMSnapshotStore()
        let fileSystem = MockFileSystem()
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            linuxImageResolveService: MockLinuxImageResolveService(),
            downloadService: MockDownloadService(),
            fileSystem: fileSystem
        )
        let library = VMLibrary(
            storageService: storage,
            snapshotStore: snapshots,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(),
            isVMNetworkingEntitled: true
        )
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
            snapshotStore: snapshots,
            diskImageService: MockDiskImageService(),
            fileSystem: fileSystem,
            preferences: preferences
        )
        let authority = MockSandboxSourceAuthority()
        core.sourceAuthority = authority
        return Harness(core: core, library: library, storage: storage, authority: authority)
    }

    /// A folder that really is one, so the share verb's directory check passes.
    private func makeFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-share-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Alpha", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux, snapshots: [VMSnapshot] = []
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots,
            library: harness.library, storage: harness.storage, preferences: preferences)
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
        #expect(descriptors.contains { $0.name == "cpus" && !$0.editableWhileRunning })
        #expect(descriptors.contains { $0.name == "ephemeral" && $0.editableWhileRunning })
        // The listing is the whole documentation of what a key takes, so a key
        // reaching it without a summary is a key nobody can set.
        for descriptor in descriptors {
            #expect(!descriptor.summary.isEmpty, "\(descriptor.name) has no summary")
        }
    }

    // MARK: - Read

    @Test("A whole-VM read answers every key the guest can have, in registry order")
    func readAnswersEveryApplicableKey() throws {
        let harness = makeHarness()
        makeInstance(in: harness, guestOS: .linux)

        let entries = try harness.core.configuration(.name("Alpha"), keys: nil)

        let applicable = VMConfigurationKeyRegistry.keys
            .filter { $0.applies(harness.library.instances[0].configuration) }
        #expect(entries.map(\.key) == applicable.map(\.name))
        // A Linux guest's scanout carries no density, so the key is left out
        // rather than reported with a value no `set` would take back.
        #expect(!entries.contains { $0.key == "display.hidpi" })
        #expect(try value(entries, "network.mode") == "none")
    }

    @Test("A named read answers in the order asked, and refuses a name the keyspace lacks")
    func namedReadKeepsTheCallersOrder() throws {
        let harness = makeHarness()
        makeInstance(in: harness)

        let entries = try harness.core.configuration(
            .name("Alpha"), keys: ["memory", "cpus"])
        #expect(entries.map(\.key) == ["memory", "cpus"])

        #expect(throws: CommandError.self) {
            try harness.core.configuration(.name("Alpha"), keys: ["cpu"])
        }
    }

    @Test("A key the guest cannot have is refused when it is named outright")
    func namedReadRefusesAnInapplicableKey() throws {
        let harness = makeHarness()
        makeInstance(in: harness, guestOS: .linux)

        do {
            _ = try harness.core.configuration(.name("Alpha"), keys: ["display.hidpi"])
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .unsupported = error else {
                Issue.record("expected unsupported, got \(error)")
                return
            }
        }
    }

    // MARK: - Write

    @Test("A set writes every assignment and answers the values they landed on")
    func setWritesAndAnswers() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        let answered = try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "cpus", value: "3"),
                ConfigurationEntry(key: "display.preference", value: "fullscreen"),
            ],
            confirmed: false)

        #expect(instance.configuration.cpuCount == 3)
        #expect(instance.configuration.displayPreference == .fullscreen)
        #expect(
            answered == [
                ConfigurationEntry(key: "cpus", value: "3"),
                ConfigurationEntry(key: "display.preference", value: "fullscreen"),
            ])
    }

    @Test("One bad value in a batch writes nothing at all")
    func aBatchIsAtomic() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let before = instance.configuration

        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [
                    ConfigurationEntry(key: "cpus", value: "3"),
                    ConfigurationEntry(key: "memory", value: "999999"),
                ],
                confirmed: false)
        }

        #expect(instance.configuration == before)
    }

    @Test("One key the state will not take writes nothing at all")
    func aRefusedGateWritesNothing() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        let before = instance.configuration

        do {
            _ = try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [
                    ConfigurationEntry(key: "clipboard.sharing", value: "true"),
                    ConfigurationEntry(key: "cpus", value: "3"),
                ],
                confirmed: false)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .invalidState = error else {
                Issue.record("expected invalidState, got \(error)")
                return
            }
        }

        #expect(instance.configuration == before)
    }

    @Test("A running VM still takes the settings read at other moments than boot")
    func liveKeysAreWritableWhileRunning() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "clipboard.sharing", value: "true"),
                ConfigurationEntry(key: "display.autoResize", value: "false"),
            ],
            confirmed: false)

        #expect(instance.configuration.clipboardSharingEnabled)
        #expect(!instance.configuration.displayAutoResizes)
    }

    @Test("A running networked VM hot-swaps its mode but cannot lose its device")
    func networkModeIsLiveSwitchableButNotRemovable() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .shared

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "network.mode", value: "hostOnly")],
            confirmed: false)
        #expect(instance.configuration.networkMode == .hostOnly)

        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "network.mode", value: "none")],
                confirmed: false)
        }
        #expect(instance.configuration.networkEnabled)
    }

    @Test("A running VM with no network device cannot be given one")
    func networkModeIsAtRestWhenThereIsNoDevice() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        #expect(!instance.configuration.networkEnabled)
        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "network.mode", value: "shared")],
                confirmed: false)
        }
        #expect(!instance.configuration.networkEnabled)
    }

    @Test("An address another VM holds is refused as a conflict, not as an alert")
    func aTakenMACAddressIsAConflict() throws {
        let harness = makeHarness()
        let alpha = makeInstance(in: harness, name: "Alpha")
        let beta = makeInstance(in: harness, name: "Beta")
        beta.configuration.macAddress = "aa:bb:cc:dd:ee:ff"
        let before = alpha.configuration

        do {
            _ = try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "network.mac", value: "AA:BB:CC:DD:EE:FF")],
                confirmed: false)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .conflict(_, let other, let reason) = error else {
                Issue.record("expected a conflict, got \(error)")
                return
            }
            #expect(other.name == "Beta")
            // The address the assignment named, canonical: what the refusal
            // tells a caller who is typing addresses at it.
            #expect(reason == .macAddressInUse(address: "aa:bb:cc:dd:ee:ff"))
            #expect(error.message.contains("aa:bb:cc:dd:ee:ff"))
        }

        #expect(alpha.configuration == before)
    }

    @Test("Turning passthrough on refuses without consent, and takes it as a parameter")
    func passthroughEnableAsksForConsent() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        instance.configuration.clipboardSharingEnabled = true

        do {
            _ = try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "clipboard.passthrough", value: "true")],
                confirmed: false)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            #expect(error.confirmationPrompt?.kind == .enableClipboardPassthrough)
        }
        #expect(!instance.configuration.clipboardPassthroughEnabled)

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "clipboard.passthrough", value: "true")],
            confirmed: true)
        #expect(instance.configuration.clipboardPassthroughEnabled)
    }

    @Test("Passthrough refuses without sharing, whichever order the pair arrives in")
    func passthroughNeedsSharing() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "clipboard.passthrough", value: "true")],
                confirmed: true)
        }
        #expect(!instance.configuration.clipboardPassthroughEnabled)

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "clipboard.passthrough", value: "true"),
                ConfigurationEntry(key: "clipboard.sharing", value: "true"),
            ],
            confirmed: true)
        #expect(instance.configuration.clipboardPassthroughEnabled)
        #expect(instance.configuration.clipboardSharingEnabled)
    }

    @Test("Turning sharing off leaves a passthrough flag already set alone")
    func turningSharingOffIsNotAPassthroughEnable() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        instance.configuration.clipboardSharingEnabled = true
        instance.configuration.clipboardPassthroughEnabled = true

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "clipboard.sharing", value: "false")],
            confirmed: false)

        #expect(!instance.configuration.clipboardSharingEnabled)
        #expect(instance.configuration.clipboardPassthroughEnabled)
    }

    @Test("Ephemeral Mode is writable while the VM runs and pins the shared baseline")
    func ephemeralIsWritableWhileRunning() throws {
        let harness = makeHarness()
        let snapshot = VMSnapshot(name: "Baseline", kind: .cold)
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()), snapshots: [snapshot])

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "ephemeral", value: "on")],
            confirmed: false)

        #expect(instance.configuration.ephemeralModeEnabled)
        #expect(instance.configuration.ephemeralBaselineSnapshotID == snapshot.id)
    }

    @Test("A VM with nothing to fall back to cannot be made ephemeral")
    func ephemeralNeedsASnapshot() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "ephemeral", value: "true")],
                confirmed: false)
        }
        #expect(!instance.configuration.ephemeralModeEnabled)
    }

    @Test("An unknown key refuses as an argument and writes nothing")
    func unknownKeysRefuse() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let before = instance.configuration

        do {
            _ = try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "cpu", value: "3")],
                confirmed: false)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .invalidArgument = error else {
                Issue.record("expected invalidArgument, got \(error)")
                return
            }
        }
        #expect(instance.configuration == before)
    }

    @Test("Every value a get answers is a value a set takes back")
    func readValuesAreWritableValues() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let before = instance.configuration

        let entries = try harness.core.configuration(.name("Alpha"), keys: nil)
        let answered = try harness.core.setConfiguration(
            .name("Alpha"), assignments: entries, confirmed: false)

        #expect(instance.configuration == before)
        #expect(answered == entries)
    }

    @Test("Turning sharing on over a passthrough flag already set asks for consent")
    func sharingEnableOverAStalePassthroughFlagAsksForConsent() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        // Reachable from both surfaces: passthrough is left set when sharing
        // goes off, and turning sharing back on starts it running again.
        instance.configuration.clipboardPassthroughEnabled = true

        do {
            _ = try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "clipboard.sharing", value: "true")],
                confirmed: false)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            #expect(error.confirmationPrompt?.kind == .enableClipboardPassthrough)
        }
        #expect(!instance.configuration.clipboardSharingEnabled)

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "clipboard.sharing", value: "true")],
            confirmed: true)
        #expect(instance.configuration.clipboardPassthroughIsEffective)
    }

    @Test("Sharing on a VM with no passthrough flag needs no consent")
    func sharingEnableAloneNeedsNoConsent() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "clipboard.sharing", value: "true")],
            confirmed: false)

        #expect(instance.configuration.clipboardSharingEnabled)
        #expect(!instance.configuration.clipboardPassthroughIsEffective)
    }

    // MARK: - Display size

    @Test("The size keys name the size the pane's fields show, not the pixels")
    func displaySizeKeysSpeakBaseSize() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, guestOS: .macOS)
        instance.configuration.displaySizesToWindow = false
        instance.configuration.displayResolution = DisplayBootSizing.Resolution(
            width: 2560, height: 1600, ppi: DisplayBootSizing.hiDPIPixelsPerInch)

        let read = try harness.core.configuration(
            .name("Alpha"), keys: ["display.width", "display.height"])
        #expect(read.map(\.value) == ["1280", "800"])

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "display.width", value: "1920"),
                ConfigurationEntry(key: "display.height", value: "1200"),
            ],
            confirmed: false)

        // Doubled for the density, exactly as the settings pane's fields write.
        #expect(instance.configuration.displayWidth == 3840)
        #expect(instance.configuration.displayHeight == 2400)
        #expect(instance.configuration.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
    }

    @Test("A size the pane would not offer is refused, whichever axis names it")
    func displaySizeBelowTheMinimumIsRefused() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, guestOS: .macOS)
        instance.configuration.displaySizesToWindow = false
        instance.configuration.displayResolution = DisplayBootSizing.Resolution(
            width: 2560, height: 1600, ppi: DisplayBootSizing.hiDPIPixelsPerInch)
        let before = instance.configuration

        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "display.width", value: "640")],
                confirmed: false)
        }
        // A HiDPI base is doubled before it reaches VZ, so it stops at half the
        // pixel ceiling rather than at the ceiling itself.
        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "display.width", value: "5000")],
                confirmed: false)
        }
        #expect(instance.configuration == before)
    }

    @Test("A size written while the display sizes to its window is refused")
    func displaySizeIsRefusedWhileSizedToWindow() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        instance.configuration.displaySizesToWindow = true
        let before = instance.configuration

        do {
            _ = try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "display.width", value: "1600")],
                confirmed: false)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .invalidArgument(let message) = error else {
                Issue.record("expected invalidArgument, got \(error)")
                return
            }
            #expect(message.contains("display.sizeToWindow"))
        }
        #expect(instance.configuration == before)

        // Writing back the value the VM already holds is still a no-op, so a
        // whole-VM `get` stays valid `set` input in this state.
        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(
                    key: "display.width", value: String(before.displayBaseSize.width))
            ],
            confirmed: false)
        #expect(instance.configuration == before)
    }

    @Test("Leaving size-to-window in the same call lets the size land, whichever order")
    func displaySizeLandsWithSizeToWindowInTheSameBatch() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        instance.configuration.displaySizesToWindow = true

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "display.width", value: "1600"),
                ConfigurationEntry(key: "display.sizeToWindow", value: "false"),
            ],
            confirmed: false)

        #expect(!instance.configuration.displaySizesToWindow)
        #expect(instance.configuration.displayWidth == 1600)
    }

    // MARK: - MAC address

    @Test("A networked VM cannot be left with no address to send from")
    func emptyMACIsRefusedWhileTheDeviceIsThere() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "network.mode", value: "shared")],
            confirmed: false)
        let before = instance.configuration
        #expect(before.macAddress != nil)

        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "network.mac", value: "")],
                confirmed: false)
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
            confirmed: false)
        #expect(instance.configuration.macAddress == nil)
        #expect(!instance.configuration.networkEnabled)
    }

    // MARK: - Persistence

    @Test("A write that never reached disk is refused rather than reported ok")
    func aFailedSaveRefuses() throws {
        let harness = makeHarness()
        makeInstance(in: harness)
        harness.storage.saveConfigurationError = CocoaError(.fileWriteNoPermission)

        do {
            _ = try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "cpus", value: "3")],
                confirmed: false)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .operationFailed(let verb, _, _, _) = error else {
                Issue.record("expected operationFailed, got \(error)")
                return
            }
            #expect(verb == .setConfiguration)
        }
    }

    @Test("A bundle still being copied takes no configuration write")
    func aPreparingVMTakesNoWrite() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .importing, task: task)
        let before = instance.configuration

        // The capability gate is the whole of what refuses this: no capability a
        // configuration key is gated on survives preparing.
        do {
            _ = try harness.core.setConfiguration(
                .name("Alpha"),
                assignments: [ConfigurationEntry(key: "clipboard.sharing", value: "true")],
                confirmed: false)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .busy = error else {
                Issue.record("expected busy, got \(error)")
                return
            }
        }
        #expect(instance.configuration == before)
    }

    // MARK: - Shared directories

    @Test("The share listing is what the VM carries, in order, without the bookmark behind it")
    func sharedDirectoriesAnswerWhatTheVMCarries() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        instance.configuration.sharedDirectories = [
            SharedDirectory(path: "/Users/somebody/Sites", readOnly: false, bookmark: Data([1, 2])),
            SharedDirectory(path: "/Users/somebody/Reference", readOnly: true),
        ]

        let listed = try harness.core.sharedDirectories(of: .name("Alpha"))

        #expect(
            listed == [
                SharedDirectorySummary(path: "/Users/somebody/Sites", readOnly: false),
                SharedDirectorySummary(path: "/Users/somebody/Reference", readOnly: true),
            ])
        // The folders are never opened, so one that has moved is still listed —
        // by the path the removal takes back.
        #expect(!FileManager.default.fileExists(atPath: "/Users/somebody/Sites"))
    }

    @Test("A VM sharing nothing lists nothing, and a selector nothing answers to is refused")
    func sharedDirectoriesOnAnEmptyAndAMissingVM() throws {
        let harness = makeHarness()
        makeInstance(in: harness)

        #expect(try harness.core.sharedDirectories(of: .name("Alpha")).isEmpty)
        #expect(throws: CommandError.self) {
            try harness.core.sharedDirectories(of: .name("Typo"))
        }
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

    @Test("A running VM takes no share edit at all")
    func shareEditsAreAtRest() async throws {
        let harness = makeHarness()
        makeInstance(in: harness, phase: .running(sessionID: UUID()))

        await #expect(throws: CommandError.self) {
            try await harness.core.addSharedDirectory(
                .name("Alpha"), path: "/Users/somebody/Sites", readOnly: false)
        }
        // The state decided the answer, so no panel was ever put on screen.
        #expect(harness.authority.requests.isEmpty)
    }

    @Test("A share for a VM nothing answers to never asks for a grant")
    func shareAddResolvesBeforeItAsks() async throws {
        let harness = makeHarness()
        makeInstance(in: harness)

        await #expect(throws: CommandError.self) {
            try await harness.core.addSharedDirectory(
                .name("Typo"), path: "/Users/somebody/Sites", readOnly: false)
        }
        #expect(harness.authority.requests.isEmpty)
    }

    @Test("A path naming anything but a folder is refused rather than stored")
    func shareAddRefusesANonDirectory() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-share-\(UUID().uuidString).txt")
        try Data("not a folder".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

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

    @Test("A VM started while the panel stood takes no share")
    func shareAddRefusesAVMStartedWhileThePanelStood() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let picked = try makeFolder("late")
        harness.authority.substitute = picked
        // The panel waits on a person, so the VM can be started under it — and
        // a share written onto a running VM is stored inert until it next boots.
        harness.authority.whilePanelStands = { instance.enter(.running(sessionID: UUID())) }

        do {
            try await harness.core.addSharedDirectory(
                .name("Alpha"), path: picked.path(percentEncoded: false), readOnly: false)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .invalidState = error else {
                Issue.record("expected invalidState, got \(error)")
                return
            }
        }
        #expect(instance.configuration.sharedDirectories == nil)
    }

    // MARK: - Port forwarding

    @Test("The forwarding listing is every rule the VM carries, in order")
    func portForwardingRulesAnswerWhatTheVMCarries() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let rules = [
            PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80),
            PortForwardingRule(transport: .udp, hostPort: 5353, guestPort: 53),
        ]
        instance.configuration.portForwardingRules = rules

        // The VM's networking is off, so a rule is listed whether or not any
        // network is carrying it right now.
        #expect(try harness.core.portForwardingRules(of: .name("Alpha")) == rules)
    }

    @Test("A VM forwarding nothing lists nothing, and a selector nothing answers to is refused")
    func portForwardingRulesOnAnEmptyAndAMissingVM() throws {
        let harness = makeHarness()
        makeInstance(in: harness)

        #expect(try harness.core.portForwardingRules(of: .name("Alpha")).isEmpty)
        #expect(throws: CommandError.self) {
            try harness.core.portForwardingRules(of: .name("Typo"))
        }
    }

    @Test("A rule is added and dropped by its host-side claim")
    func portForwardingRoundTrips() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let rule = PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80)

        try harness.core.addPortForwardingRule(.name("Alpha"), rule: rule)
        #expect(instance.configuration.portForwardingRules == [rule])

        try harness.core.removePortForwardingRule(.name("Alpha"), claim: rule.hostClaim)
        #expect(instance.configuration.portForwardingRules.isEmpty)
    }

    @Test("A host port another VM already claims is refused, naming the holder")
    func hostPortCollisionsRefuse() throws {
        let harness = makeHarness()
        let alpha = makeInstance(in: harness, name: "Alpha")
        let beta = makeInstance(in: harness, name: "Beta")
        beta.configuration.portForwardingRules = [
            PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 8080)
        ]

        do {
            try harness.core.addPortForwardingRule(
                .name("Alpha"),
                rule: PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80))
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .invalidArgument(let message) = error else {
                Issue.record("expected invalidArgument, got \(error)")
                return
            }
            #expect(message.contains("Beta"))
        }
        #expect(alpha.configuration.portForwardingRules.isEmpty)

        // The same host port on the other transport is a different claim.
        try harness.core.addPortForwardingRule(
            .name("Alpha"),
            rule: PortForwardingRule(transport: .udp, hostPort: 8080, guestPort: 80))
        #expect(alpha.configuration.portForwardingRules.count == 1)
    }

    @Test("Adding the rule the VM already carries changes nothing")
    func addingAnIdenticalRuleIsIdempotent() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let rule = PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80)
        try harness.core.addPortForwardingRule(.name("Alpha"), rule: rule)

        try harness.core.addPortForwardingRule(.name("Alpha"), rule: rule)

        #expect(instance.configuration.portForwardingRules == [rule])
    }

    @Test("This VM's own rule on the same host port names itself, not a collision")
    func aDifferentGuestPortOnItsOwnClaimNamesTheRule() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Alpha")
        let existing = PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80)
        try harness.core.addPortForwardingRule(.name("Alpha"), rule: existing)

        do {
            try harness.core.addPortForwardingRule(
                .name("Alpha"),
                rule: PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 8081))
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .invalidArgument(let message) = error else {
                Issue.record("expected invalidArgument, got \(error)")
                return
            }
            #expect(message.contains("8081") == false)
            #expect(message.contains("guest port 80"))
        }
        #expect(instance.configuration.portForwardingRules == [existing])
    }

    @Test("A rule this VM does not carry cannot be dropped")
    func removingAnAbsentRuleRefuses() throws {
        let harness = makeHarness()
        makeInstance(in: harness)

        #expect(throws: CommandError.self) {
            try harness.core.removePortForwardingRule(
                .name("Alpha"),
                claim: PortForwardingHostClaim(transport: .tcp, hostPort: 8080))
        }
    }

    @Test("A port that addresses no service is refused")
    func portZeroIsRefused() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        #expect(throws: CommandError.self) {
            try harness.core.addPortForwardingRule(
                .name("Alpha"),
                rule: PortForwardingRule(transport: .tcp, hostPort: 0, guestPort: 80))
        }
        #expect(instance.configuration.portForwardingRules.isEmpty)
    }

    @Test("A running VM takes no forwarding edit")
    func forwardingEditsAreAtRest() throws {
        let harness = makeHarness()
        makeInstance(in: harness, phase: .running(sessionID: UUID()))

        #expect(throws: CommandError.self) {
            try harness.core.addPortForwardingRule(
                .name("Alpha"),
                rule: PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80))
        }
    }
}
