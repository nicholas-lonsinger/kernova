import Foundation
import KernovaCommandModel
import KernovaLogging
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What this copy does with a VM another running copy of Kernova holds while
/// it rests here: an edit is refused inside its coordinated write, the VM
/// claims its identity against every bring-up, and each event-driven refresh
/// marks the hold, clears it, and re-reads what the other copy wrote.
@Suite("Another copy's hold", .caseScoped)
@MainActor
struct VMOtherCopyHoldTests {
    /// An in-memory store that counts each run-lock probe made inside a
    /// coordinated write — so a test can tell the in-write check from
    /// admission's probe, which runs before any write.
    private final class WriteObservingBundleFiles: VMBundleFileAccessing {
        private struct Writes {
            var open = 0
            var probesInside = 0
        }

        let store = InMemoryVMBundleFiles()
        private let writes = Mutex(Writes())

        var probesInsideWrite: Int { writes.withLock { $0.probesInside } }

        func lockBundle(at bundleURL: URL) throws -> (any VMBundleLockHolder)? {
            try store.lockBundle(at: bundleURL)
        }

        func isBundleLockedElsewhere(at bundleURL: URL) throws -> Bool {
            writes.withLock {
                if $0.open > 0 { $0.probesInside += 1 }
            }
            return try store.isBundleLockedElsewhere(at: bundleURL)
        }

        func reading<T>(_ bundleURL: URL, _ body: (any VMBundleFileReading) throws -> T) throws -> T {
            try store.reading(bundleURL, body)
        }

        func writing<T>(
            _ bundleURL: URL, _ key: borrowing VMBundleFileWriteKey,
            _ body: (any VMBundleFileWriting) throws -> T
        ) throws -> T {
            writes.withLock { $0.open += 1 }
            defer { writes.withLock { $0.open -= 1 } }
            return try store.writing(bundleURL, key, body)
        }
    }

    /// A VM at rest whose bundle files are read and written through `access`.
    private func makeInstance(over access: WriteObservingBundleFiles) -> VMInstance {
        let config = VMConfiguration(
            name: "Watched", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let url = VMInstanceFixture.bundleURL(for: config.id)
        access.store.seed(config, at: url)
        return VMInstance(
            bundle: VMBundle.Factory(machineFiles: MockVMBundleMachineFiles(files: access.store))
                .make(VMInstanceFixture.read(url, from: access)),
            phase: .stopped, preferences: makeTestPreferences(),
            hostPasteboard: FakePasteboard(), bundleProducts: .testing, logSink: nil)
    }

    // MARK: - Edits

    @Test("An edit whose bundle another copy takes after admission is refused inside the write")
    func editIsRefusedInsideTheWrite() throws {
        let access = WriteObservingBundleFiles()
        let instance = makeInstance(over: access)
        let url = instance.bundleURL
        let before = try #require(access.store.configuration(at: url))

        #expect(throws: VMAdmissionRefusal(refusal: .heldByAnotherCopy)) {
            try instance.activity.edit(.liveKeys) { permit in
                // Past admission: only the check inside the write can see it.
                access.store.holdElsewhere(url)
                try permit.bundle.commitConfiguration { $0.serialSocketRelayEnabled.toggle() }
            }
        }

        #expect(access.probesInsideWrite == 1)
        #expect(access.store.configuration(at: url) == before)
        #expect(instance.configuration == before)
        #expect(instance.activity.heldByAnotherCopy)
    }

    @Test("A library write refused for another copy's hold answers the refusal and presents nothing")
    func libraryWriteAnswersTheRefusal() throws {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let failures = MockLibraryFailureSink()
        library.onFailure = { [failures] title, message, subject in
            failures.record(title: title, message: message, subject: subject)
        }
        let instance = library.registerFixture()
        let url = instance.bundleURL

        let write = try instance.activity.edit(.liveKeys) { permit in
            storage.files.holdElsewhere(url)
            return library.updateConfiguration(permit) { $0.serialSocketRelayEnabled.toggle() }
        }

        guard case .refused(.heldByAnotherCopy) = write else {
            Issue.record("The write answered \(write)")
            return
        }
        #expect(!failures.showError)
        #expect(instance.activity.heldByAnotherCopy)
    }

    // MARK: - Identity

    nonisolated private static let sharedMAC = "02:4b:4e:56:00:01"

    /// What two twins share.
    enum Twinning: Sendable, CustomTestStringConvertible {
        case macAddress
        case machineIdentity
        /// Both — refused on the MAC address, which no override waives.
        case both

        /// What the second twin's start is refused on.
        /// A shared machine identity is answered before a MAC address.
        var reason: ConflictReason {
            self == .macAddress ? .macAddress : .machineIdentity(overrideSettingOn: false)
        }

        var testDescription: String {
            switch self {
            case .macAddress: "MAC address"
            case .machineIdentity: "machine identity"
            case .both: "machine identity and MAC address"
            }
        }
    }

    /// Makes the `index`th VM of a pair sharing what `twinning` names.
    nonisolated private static func twin(
        _ twinning: Twinning, index: UInt8, identity: Data
    ) -> (inout VMConfiguration) -> Void {
        { config in
            config.networkEnabled = true
            switch twinning {
            case .macAddress:
                config.macAddress = sharedMAC
            case .machineIdentity:
                config.genericMachineIdentifierData = identity
                config.macAddress = String(format: "02:4b:4e:56:01:%02x", index)
            case .both:
                config.genericMachineIdentifierData = identity
                config.macAddress = sharedMAC
            }
        }
    }

    @Test(
        "A twin of a VM another copy holds is refused, naming the source",
        arguments: [Twinning.macAddress, .machineIdentity, .both])
    func twinOfAHeldVMIsRefused(twinning: Twinning) {
        let label = twinning.testDescription
        let reason = twinning.reason
        let storage = MockVMStorageService()
        let preferences = makeTestPreferences()
        let library = makeWiredLibrary(storage: storage, preferences: preferences)
        let identity = Data([7, 7, 7])
        let source = library.registerFixture(
            name: "Source", preferences: preferences,
            mutate: Self.twin(twinning, index: 1, identity: identity))
        let copy = library.registerFixture(
            name: "Copy", preferences: preferences,
            mutate: Self.twin(twinning, index: 2, identity: identity))
        storage.files.holdElsewhere(source.bundleURL)

        let decision = copy.activity.decide(.start(recovery: false), posture: .commit)

        guard case .refuse(.identityConflict(let conflict)) = decision else {
            Issue.record("\(label): decided \(decision)")
            return
        }
        #expect(conflict.other === source, "\(label)")
        #expect(conflict.reason == reason, "\(label)")
        #expect(source.activity.heldByAnotherCopy, "\(label)")

        // The check caught the source up first, so a hold that ended admits.
        storage.files.releaseElsewhere(source.bundleURL)
        #expect(copy.activity.decide(.start(recovery: false), posture: .commit) == .admit, "\(label)")
        #expect(!source.activity.heldByAnotherCopy, "\(label)")
    }

    /// Registers "Starting" and `otherName`, both at rest with networking on
    /// and distinct MAC addresses, then has another copy rewrite `otherName`'s
    /// configuration on disk to carry Starting's MAC address. The library is
    /// answered so the test keeps it alive: its VMs reach it weakly.
    private func registerStartingAndRewrittenOther(
        named otherName: String
    ) throws -> (
        library: VMLibrary, storage: MockVMStorageService, starting: VMInstance, other: VMInstance,
        otherMAC: String?
    ) {
        let storage = MockVMStorageService()
        let preferences = makeTestPreferences()
        let library = makeWiredLibrary(storage: storage, preferences: preferences)
        let starting = library.registerFixture(
            name: "Starting", preferences: preferences,
            mutate: Self.twin(.macAddress, index: 1, identity: Data()))
        let other = library.registerFixture(
            name: otherName, preferences: preferences,
            mutate: { config in
                config.networkEnabled = true
                config.macAddress = "02:4b:4e:56:02:02"
            })
        let otherMAC = other.configuration.macAddress
        try VMStagedBundle.fixtureForTesting(at: other.bundleURL, access: storage.files)
            .update(.configuration) { $0.macAddress = starting.configuration.macAddress }
        return (library, storage, starting, other, otherMAC)
    }

    @Test("A bring-up's identity check reads no bundle another copy does not hold")
    func identityCheckSkipsUnheldBundles() throws {
        let (library, storage, starting, idle, idleMAC) = try registerStartingAndRewrittenOther(named: "Idle")
        let reads = storage.files.readCount(of: VMBundleLayout.configRelativePath)

        #expect(starting.activity.decide(.start(recovery: false), posture: .commit) == .admit)

        #expect(storage.files.readCount(of: VMBundleLayout.configRelativePath) == reads)
        #expect(idle.configuration.macAddress == idleMAC)
        withExtendedLifetime(library) {}
    }

    @Test("A bring-up's identity check re-reads a bundle another copy holds, and claims what it carries now")
    func identityCheckReReadsHeldBundles() throws {
        let (library, storage, starting, held, _) = try registerStartingAndRewrittenOther(named: "Held")
        storage.files.holdElsewhere(held.bundleURL)
        let reads = storage.files.readCount(of: VMBundleLayout.configRelativePath)

        let decision = starting.activity.decide(.start(recovery: false), posture: .commit)

        guard case .refuse(.identityConflict(let conflict)) = decision else {
            Issue.record("decided \(decision)")
            return
        }
        #expect(conflict.other === held)
        #expect(conflict.reason == .macAddress)
        #expect(storage.files.readCount(of: VMBundleLayout.configRelativePath) == reads + 1)
        #expect(held.configuration.macAddress == starting.configuration.macAddress)
        withExtendedLifetime(library) {}
    }

    // MARK: - Refreshes

    @Test("The launch load reads each bundle once, and answers the VMs it read marked to start automatically")
    func launchLoadReadsOnceAndAnswersMarked() async throws {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let marked = VMConfiguration(
            name: "Marked", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let unmarked = VMConfiguration(
            name: "Unmarked", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let markedURL = try storage.bundleURL(for: marked)
        storage.setConfiguration(marked, at: markedURL)
        storage.setConfiguration(unmarked, at: try storage.bundleURL(for: unmarked))
        storage.files.setHostState(VMHostState(startsAutomaticallyOnLaunch: true), at: markedURL)
        let reads = storage.files.readCount(of: VMBundleLayout.configRelativePath)

        let answered = await library.startLibrary()

        #expect(answered == [marked.id])
        #expect(storage.files.readCount(of: VMBundleLayout.configRelativePath) == reads + 2)
    }

    @Test("A refresh re-derives where the VM rests from a suspend slot another copy left")
    func refreshReDerivesTheRest() throws {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = library.registerFixture()
        try VMInstanceFixture.writeSaveFile(for: instance)

        library.refreshFromOtherCopies()

        #expect(instance.phase == .suspended)
    }

    // MARK: - Records

    @Test("A refused set records one refusal, naming the verb, and the hold it found once")
    func refusedSetRecordsOnce() throws {
        let capture = LogCapture()
        let harness = makeCore(loggingTo: capture)
        let name = "Held set"
        let instance = harness.library.registerFixture(name: name)
        harness.storage.files.holdElsewhere(instance.bundleURL)

        #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .id(instance.id),
                assignments: [ConfigurationEntry(key: "serial.socket", value: "true")],
                consent: .all)
        }

        #expect(capture.refusals.count == 1, "\(capture.messages)")
        #expect(capture.refusals.first?.hasPrefix("Refused setConfiguration for '\(name)'") == true)
        #expect(capture.holdTransitions.count == 1, "\(capture.messages)")
        #expect(!capture.messages.contains { $0.contains("rawValue") }, "\(capture.messages)")
    }

    @Test("A refused revert records one refusal, and names no snapshot")
    func refusedRevertRecordsOnce() async throws {
        let capture = LogCapture()
        let harness = makeCore(loggingTo: capture)
        let name = "Held revert"
        let snapshot = VMSnapshot(name: "Only", kind: .cold, macAddress: nil)
        let instance = harness.library.registerFixture(
            name: name, snapshots: VMSnapshotManifest(snapshots: [snapshot]))
        harness.storage.files.holdElsewhere(instance.bundleURL)

        await #expect(throws: CommandError.self) {
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, consent: .all)
        }

        #expect(capture.refusals.count == 1, "\(capture.messages)")
        #expect(capture.refusals.first?.hasPrefix("Refused revertToSnapshot for '\(name)'") == true)
        let uuid = /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/
        #expect(!capture.messages.contains { $0.contains(uuid) }, "\(capture.messages)")
    }

    // MARK: - Snapshot delete

    /// Memory reads the snapshot as a plain one, so the delete is admitted;
    /// taking the run lock re-reads the host state another copy wrote, which
    /// names it as the Ephemeral baseline — and the decision made again under
    /// the permit refuses it.
    @Test("A snapshot another copy made the Ephemeral baseline is refused under the permit")
    func baselineAnotherCopyNamedIsRefusedUnderThePermit() async throws {
        let harness = makeCore()
        let snapshot = VMSnapshot(name: "Clean install", macAddress: nil)
        let instance = harness.library.registerFixture(
            snapshots: VMSnapshotManifest(snapshots: [snapshot]))
        // Another process's write, which this copy's memory has not seen.
        try VMStagedBundle.fixtureForTesting(at: instance.bundleURL, access: harness.storage.files)
            .update(.hostState) { $0.applyEphemeralMode(enabled: true, baseline: snapshot.id) }
        #expect(!instance.hostState.ephemeralModeEnabled)

        await #expect(
            throws: CommandError.stepRequired(
                harness.core.ephemeralBaselineDeleteRefusal(snapshot, on: instance))
        ) {
            try await harness.core.deleteSnapshot(
                .id(instance.id), snapshot: snapshot.id, consent: Consent([.deleteSnapshot]))
        }

        #expect(instance.ephemeralBaselineSnapshot?.id == snapshot.id)
        #expect(instance.snapshotManifest.snapshots.map(\.id) == [snapshot.id])
        #expect(harness.storage.files.manifest(at: instance.bundleURL)?.snapshots.map(\.id) == [snapshot.id])
        #expect(harness.machineFiles.discardedIDs.isEmpty)
    }

    // MARK: - Harness

    private func makeCore() -> WiredCommandCore {
        WiredCommandCore()
    }

    /// A core whose verbs, library and VMs log to `capture`.
    private func makeCore(loggingTo capture: LogCapture) -> WiredCommandCore {
        WiredCommandCore(logSink: capture.sink)
    }
}

extension LogCapture {
    /// The records a refused verb leaves.
    fileprivate var refusals: [String] { messages.filter { $0.hasPrefix("Refused ") } }

    /// The records a change of another copy's hold leaves.
    fileprivate var holdTransitions: [String] {
        messages.filter {
            ($0.hasPrefix("Found '") && $0.hasSuffix("' held by another copy of Kernova"))
                || $0.hasPrefix("Another copy of Kernova no longer holds")
        }
    }
}
