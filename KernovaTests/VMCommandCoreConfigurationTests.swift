import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The configuration verbs against a real library: the keyspace read and
/// written through the core's own gates, the shared-directory edits a caller
/// names by path, and every refusal each of them owes.
@Suite("VMCommandCore Configuration Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreConfigurationTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMCommandCoreConfigurationTests")

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let storage: MockVMStorageService
        let authority: MockSandboxSourceAuthority
    }

    private func makeHarness() -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMBundleMachineFiles()
        let fileSystem = MockFileSystem()
        let lifecycle = makeTestLifecycle(
            virtualization: MockVirtualizationService(),
            fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage,
            machineFiles: snapshots,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences)
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
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
        let url = scratch.url.appendingPathComponent(
            "kernova-share-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Alpha", phase: VMLifecyclePhase = .stopped,
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
        #expect(instance.hostState.displayPreference == .fullscreen)
        #expect(
            answered == [
                ConfigurationEntry(key: "cpus", value: "3"),
                ConfigurationEntry(key: "display.preference", value: "fullscreen"),
            ])
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
            confirmed: false)

        let configuration = try #require(harness.storage.bundles[instance.bundleURL])
        #expect(configuration.memorySizeInGB == onDisk.memorySizeInGB)
        #expect(!configuration.displayAutoResizes)
        #expect(harness.storage.hostStates[instance.bundleURL]?.displayPreference == .fullscreen)
        #expect(instance.configuration == configuration)
        #expect(instance.hostState == harness.storage.hostStates[instance.bundleURL])
    }

    @Test("A set of the value memory holds is written when the bundle holds another")
    func anAssignmentIsJudgedAgainstTheBundle() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let held = instance.configuration.cpuCount
        // Another Kernova copy changed the count after this one read the bundle.
        var onDisk = instance.configuration
        onDisk.cpuCount = held + 1
        harness.storage.files.setConfiguration(onDisk, at: instance.bundleURL)

        let answered = try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [ConfigurationEntry(key: "cpus", value: String(held))],
            confirmed: false)

        #expect(try value(answered, "cpus") == String(held))
        #expect(harness.storage.bundles[instance.bundleURL]?.cpuCount == held)
        #expect(instance.configuration.cpuCount == held)
    }

    @Test("A running VM refuses the value memory holds when it would move the bundle's")
    func aRunningVMRefusesWhatMovesTheBundle() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        let held = instance.configuration.cpuCount
        var onDisk = instance.configuration
        onDisk.cpuCount = held + 1
        harness.storage.files.setConfiguration(onDisk, at: instance.bundleURL)
        let assignment = ConfigurationEntry(key: "cpus", value: String(held))

        do {
            try harness.core.setConfiguration(
                .name("Alpha"), assignments: [assignment], confirmed: false)
            Issue.record("expected a refusal")
        } catch let error as CommandError {
            guard case .invalidState(_, _, _, let settings) = error else {
                Issue.record("expected invalidState, got \(error)")
                return
            }
            #expect(settings == [assignment])
        }
        #expect(harness.storage.bundles[instance.bundleURL]?.cpuCount == held + 1)
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
        try harness.core.setConfiguration(.name("Alpha"), assignments: read, confirmed: false)

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
        try harness.core.setConfiguration(.name("Alpha"), assignments: read, confirmed: false)

        #expect(instance.configuration == before)
        #expect(harness.storage.bundles[instance.bundleURL] == onDisk)
    }

    @Test("A Retina base size down to 1 is taken, not refused")
    func aRetinaBaseTakesTheFrameworksFloor() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, guestOS: .macOS) {
            $0.displaySizesToWindow = false
            $0.displayHiDPI = true
            $0.displayResolution = DisplayBootSizing.Resolution(
                width: 1920, height: 1200, ppi: DisplayBootSizing.hiDPIPixelsPerInch)
        }

        try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "display.width", value: "1"),
                ConfigurationEntry(key: "display.height", value: "1"),
            ],
            confirmed: false)

        #expect(instance.configuration.displayWidth == 2)
        #expect(instance.configuration.displayHeight == 2)
        #expect(instance.configuration.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
    }

    @Test("A size below 1 is refused, whichever axis names it")
    func displaySizeBelowTheMinimumIsRefused() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, guestOS: .macOS) {
            $0.displaySizesToWindow = false
            $0.displayResolution = DisplayBootSizing.Resolution(
                width: 2560, height: 1600, ppi: DisplayBootSizing.hiDPIPixelsPerInch)
        }
        let before = instance.configuration

        for key in ["display.width", "display.height"] {
            #expect(throws: CommandError.self) {
                try harness.core.setConfiguration(
                    .name("Alpha"), assignments: [ConfigurationEntry(key: key, value: "0")],
                    confirmed: false)
            }
        }
        #expect(instance.configuration == before)
    }

    @Test("A size written while the display sizes to its window is refused")
    func displaySizeIsRefusedWhileSizedToWindow() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness) { $0.displaySizesToWindow = true }
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
        let instance = makeInstance(in: harness) { $0.displaySizesToWindow = true }

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
            confirmed: false)

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

    @Test("Clearing the address while giving the VM a network lands whole")
    func emptyMACWithANewNetworkLandsWhole() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness) {
            $0.networkEnabled = false
            $0.macAddress = nil
        }

        // The mode's write mints the address the empty spelling cleared a
        // moment before, and the result is judged once, on what both left.
        let answered = try harness.core.setConfiguration(
            .name("Alpha"),
            assignments: [
                ConfigurationEntry(key: "network.mac", value: ""),
                ConfigurationEntry(key: "network.mode", value: "shared"),
            ],
            confirmed: false)

        let configuration = try #require(harness.storage.bundles[instance.bundleURL])
        #expect(configuration.networkEnabled)
        let minted = try #require(configuration.macAddress)
        #expect(instance.configuration == configuration)
        #expect(try value(answered, "network.mac") == minted)
        #expect(try value(answered, "network.mode") == "shared")
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
                ConfigurationEntry(key: "network.mode", value: "shared"),
                ConfigurationEntry(key: "cpus", value: "3"),
            ],
            confirmed: false)

        let configuration = try #require(harness.storage.bundles[instance.bundleURL])
        #expect(configuration.networkEnabled)
        #expect(configuration.macAddress != nil)
        #expect(configuration.cpuCount == 3)
        #expect(harness.storage.hostStates[instance.bundleURL]?.displayPreference == .popOut)
        #expect(instance.configuration == configuration)
        #expect(instance.hostState == harness.storage.hostStates[instance.bundleURL])
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
    func anArrivalTakesNoWrite() async throws {
        let harness = makeHarness()
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(named: "Alpha", gate: gate)

        // Resolution is the whole of what refuses this: an arrival is no VM, so
        // no configuration write can name one.
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
        #expect(harness.storage.saveConfigurationCallCount == 0)

        gate.release()
        await arrival.settle()
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

    @Test("A VM started while the panel stood takes no share")
    func shareAddRefusesAVMStartedWhileThePanelStood() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let picked = try makeFolder("late")
        harness.authority.substitute = picked
        // The panel waits on a person, so the VM can be started under it — and
        // a share written onto a running VM is stored inert until it next boots.
        harness.authority.whilePanelStands = { instance.activity.placeForTesting(.running(sessionID: UUID())) }

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
}
