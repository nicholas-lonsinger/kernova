import Foundation
import KernovaKit
import KernovaLogging
import KernovaTestSupport
import Testing

@testable import Kernova

/// What this copy does with a VM another running copy of Kernova holds while
/// it rests here: an edit is refused inside its coordinated write, the VM
/// claims its identity against every bring-up, and each event-driven refresh
/// marks the hold, clears it, and re-reads what the other copy wrote.
@Suite("Another copy's hold", .serialized, .caseScoped)
@MainActor
struct VMOtherCopyHoldTests {
    /// An in-memory store that counts each run-lock probe made inside a
    /// coordinated write — so a test can tell the in-write check from
    /// admission's probe, which runs before any write.
    private final class WriteObservingBundleFiles: VMBundleFileAccessing, @unchecked Sendable {
        let store = InMemoryVMBundleFiles()
        private let lock = NSLock()
        private var openWrites = 0
        private var inside = 0

        var probesInsideWrite: Int { lock.withLock { inside } }

        func lockBundle(at bundleURL: URL) throws -> (any VMBundleLockHolder)? {
            try store.lockBundle(at: bundleURL)
        }

        func isBundleLockedElsewhere(at bundleURL: URL) throws -> Bool {
            lock.withLock {
                if openWrites > 0 { inside += 1 }
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
            lock.withLock { openWrites += 1 }
            defer { lock.withLock { openWrites -= 1 } }
            return try store.writing(bundleURL, key, body)
        }
    }

    /// A VM at rest whose bundle files are read and written through `access`.
    private func makeInstance(over access: WriteObservingBundleFiles) -> VMInstance {
        let config = VMConfiguration(name: "Watched", guestOS: .linux, bootMode: .efi)
        let url = VMInstanceFixture.bundleURL(for: config.id)
        access.store.seed(config, at: url)
        return VMInstance(
            bundle: VMBundle.Factory(machineFiles: MockVMBundleMachineFiles(files: access.store))
                .make(VMInstanceFixture.read(url, from: access)),
            phase: .stopped, preferences: makeTestPreferences())
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

    @Test("An edit no other copy holds the bundle for lands, having asked inside the write")
    func editLandsWhenNoOtherCopyHolds() throws {
        let access = WriteObservingBundleFiles()
        let instance = makeInstance(over: access)
        let enabled = instance.configuration.serialSocketRelayEnabled

        try instance.activity.edit(.liveKeys) { permit in
            try permit.bundle.commitConfiguration { $0.serialSocketRelayEnabled = !enabled }
        }

        #expect(access.probesInsideWrite == 1)
        #expect(access.store.configuration(at: instance.bundleURL)?.serialSocketRelayEnabled == !enabled)
        #expect(!instance.activity.heldByAnotherCopy)
    }

    @Test("A write while this copy holds the run lock asks nothing: the probe would see this copy's own lock")
    func writeUnderTheRunLockIsNotProbed() async throws {
        let access = WriteObservingBundleFiles()
        let instance = makeInstance(over: access)
        let enabled = instance.configuration.serialSocketRelayEnabled

        try await instance.activity.perform(.deletingSnapshot) { context in
            try context.permit.bundle.commitConfiguration { $0.serialSocketRelayEnabled = !enabled }
            return .rest(.asStarted, ())
        }

        #expect(access.probesInsideWrite == 0)
        #expect(access.store.configuration(at: instance.bundleURL)?.serialSocketRelayEnabled == !enabled)
    }

    @Test("A library write refused for another copy's hold answers the refusal and presents nothing")
    func libraryWriteAnswersTheRefusal() throws {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let failures = MockLibraryFailureSink()
        library.onFailure = { [failures] title, message in failures.record(title: title, message: message) }
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

    @Test("set on a VM another copy holds is refused as that copy's hold")
    func setIsRefusedWhileHeldElsewhere() throws {
        let harness = makeCore()
        let instance = harness.library.registerFixture(name: "Held")
        harness.store.holdElsewhere(instance.bundleURL)
        let before = instance.configuration

        do {
            try harness.core.setConfiguration(
                .id(instance.id),
                assignments: [
                    ConfigurationEntry(
                        key: "serial.socket", value: String(!before.serialSocketRelayEnabled))
                ],
                consent: .all)
            Issue.record("The set was not refused")
        } catch let error as CommandError {
            guard case .heldByAnotherCopy(let vm) = error else {
                Issue.record("Refused as \(error)")
                return
            }
            #expect(vm.id == instance.id)
            #expect(vm.heldByAnotherCopy)
        }
        #expect(harness.store.configuration(at: instance.bundleURL) == before)
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
        var reason: ConflictReason {
            self == .machineIdentity ? .machineIdentity : .macAddress
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

    @Test(
        "A twin's refusal names the other copy for a held source, and a stop step only for one live here",
        arguments: [Twinning.macAddress, .machineIdentity, .both])
    func twinRefusalWordsWhoClaimsTheIdentity(twinning: Twinning) throws {
        let label = twinning.testDescription
        for held in [false, true] {
            let harness = makeCore()
            let preferences = harness.preferences
            let source = harness.library.registerFixture(
                name: "Source", phase: held ? .stopped : .running(sessionID: UUID()),
                preferences: preferences, mutate: Self.twin(twinning, index: 1, identity: Data([4, 2])))
            let copy = harness.library.registerFixture(
                name: "Copy", preferences: preferences,
                mutate: Self.twin(twinning, index: 2, identity: Data([4, 2])))
            if held { harness.store.holdElsewhere(source.bundleURL) }

            guard
                case .refuse(let refusal) = copy.activity.decide(.start(recovery: false), posture: .commit),
                case .identityConflict(let conflict) = refusal
            else {
                Issue.record("\(label) held=\(held): not refused as a conflict")
                continue
            }
            let inProcess = try #require(conflict.errorDescription)
            let overTheWire = harness.core.commandError(for: refusal, on: copy).dto.message
            for message in [inProcess, overTheWire] {
                #expect(
                    message.contains("\u{201C}Source\u{201D}, which another copy of Kernova is using") == held,
                    "\(label) held=\(held): \(message)")
                #expect(
                    message.contains("\u{201C}Source\u{201D}, which is active") == !held,
                    "\(label) held=\(held): \(message)")
                #expect(
                    message.contains("Stop \u{201C}Source\u{201D}") == !held,
                    "\(label) held=\(held): \(message)")
            }
        }
    }

    // MARK: - Refreshes

    @Test("The launch load marks a VM another copy holds")
    func launchLoadMarks() async throws {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let config = VMConfiguration(name: "Held", guestOS: .linux, bootMode: .efi)
        let url = try storage.bundleURL(for: config)
        storage.bundles[url] = config
        storage.files.holdElsewhere(url)

        await library.startLibrary()

        let instance = try #require(library.instances.first)
        #expect(instance.activity.heldByAnotherCopy)
    }

    @Test("A reconcile pass marks a VM another copy holds, and clears the mark once it lets go")
    func reconcileMarksAndClears() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = library.registerFixture()

        storage.files.holdElsewhere(instance.bundleURL)
        library.reconcileWithDisk()
        #expect(instance.activity.heldByAnotherCopy)

        storage.files.releaseElsewhere(instance.bundleURL)
        library.reconcileWithDisk()
        #expect(!instance.activity.heldByAnotherCopy)
    }

    @Test("The activation refresh marks a VM another copy holds, and clears the mark once it lets go")
    func activationRefreshMarksAndClears() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = library.registerFixture()

        storage.files.holdElsewhere(instance.bundleURL)
        library.refreshFromOtherCopies()
        #expect(instance.activity.heldByAnotherCopy)

        storage.files.releaseElsewhere(instance.bundleURL)
        library.refreshFromOtherCopies()
        #expect(!instance.activity.heldByAnotherCopy)
    }

    @Test("list, info and get each mark a VM another copy holds, and clear the mark once it lets go")
    func cliReadsMarkAndClear() throws {
        let harness = makeCore()
        let instance = harness.library.registerFixture()
        let url = instance.bundleURL
        let reads: [(String, () throws -> Bool)] = [
            ("list", { harness.core.list(.all).first { $0.id == instance.id }?.heldByAnotherCopy ?? false }),
            ("info", { try harness.core.info(.id(instance.id)).heldByAnotherCopy }),
            (
                "get",
                {
                    _ = try harness.core.configuration(.id(instance.id), keys: nil)
                    return instance.activity.heldByAnotherCopy
                }
            ),
        ]
        for (verb, read) in reads {
            harness.store.holdElsewhere(url)
            #expect(try read(), "\(verb)")
            #expect(instance.activity.heldByAnotherCopy, "\(verb)")

            harness.store.releaseElsewhere(url)
            #expect(try !read(), "\(verb)")
            #expect(!instance.activity.heldByAnotherCopy, "\(verb)")
        }
    }

    @Test("A refresh re-reads what another copy wrote while this copy held no lock")
    func refreshReReadsAnotherCopysEdit() throws {
        let harness = makeCore()
        let instance = harness.library.registerFixture()
        let enabled = instance.configuration.clipboardSharingEnabled
        // Another process's write, which this copy's memory has not seen.
        try VMStagedBundle.fixtureForTesting(at: instance.bundleURL, access: harness.store)
            .update(.configuration) { $0.clipboardSharingEnabled = !enabled }
        #expect(instance.configuration.clipboardSharingEnabled == enabled)

        let entries = try harness.core.configuration(.id(instance.id), keys: ["clipboard.sharing"])

        #expect(entries == [ConfigurationEntry(key: "clipboard.sharing", value: String(!enabled))])
        #expect(instance.configuration.clipboardSharingEnabled == !enabled)
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

    @Test("A refresh leaves a VM this copy is running alone")
    func refreshSkipsALiveVM() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = library.registerFixture(phase: .running(sessionID: UUID()))
        storage.files.holdElsewhere(instance.bundleURL)

        library.refreshFromOtherCopies()

        #expect(!instance.activity.heldByAnotherCopy)
        #expect(instance.phase.isSettledLive)
    }

    // MARK: - Surfaces

    @Test("A VM another copy holds reads as in use by it, in the dimmed running color")
    func displayNamesTheHold() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = library.registerFixture()
        storage.files.holdElsewhere(instance.bundleURL)
        library.refreshFromOtherCopies()

        #expect(instance.statusDisplayName == "In use by another copy of Kernova")
        #expect(instance.statusToolTip == "In use by another copy of Kernova.")
        #expect(instance.statusDisplayNSColor == StatusColor.heldByAnotherCopy)
    }

    @Test("Every edit a surface offers on a VM another copy holds is dimmed through the catalog")
    func editsDimWhileHeld() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let catalog = VMCapabilityCatalog(library: library)
        let instance = library.registerFixture(guestOS: .macOS)
        let editing: [VMCapability] = [
            .editConfiguration, .editLiveConfiguration, .switchNetworkMode, .editStorageDisks,
            .editSharedDirectories, .rename,
        ]
        for capability in editing {
            #expect(catalog.isAvailable(capability, on: instance), "\(capability)")
        }

        storage.files.holdElsewhere(instance.bundleURL)
        library.refreshFromOtherCopies()

        for capability in editing {
            #expect(catalog.isApplicable(capability, to: instance), "\(capability)")
            #expect(!catalog.isAvailable(capability, on: instance), "\(capability)")
        }
        for category in [VMSettingsCategory.general, .sharing] {
            let toggles = VMOverviewSummary.toggles(
                for: category, instance: instance, capabilities: catalog)
            #expect(!toggles.isEmpty)
            #expect(toggles.allSatisfy { !$0.isEnabled }, "\(category)")
        }
    }

    // MARK: - Records

    /// Every log record naming `vmName` while installed, through the logger's
    /// forwarding sink.
    ///
    /// The sink is process-wide, so this suite runs `.serialized` and each test
    /// names its VM uniquely: a record another suite emits meanwhile names a
    /// VM of its own.
    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        private let vmName: String

        init(naming vmName: String) {
            self.vmName = vmName
            KernovaLogger.forwardingSink = { [self] _, subsystem, _, segments in
                let text = segments.map(\.text).joined()
                guard subsystem.hasPrefix("app.kernova"), text.contains("'\(self.vmName)'") else {
                    return
                }
                lock.withLock { recorded.append(text) }
            }
        }

        func uninstall() {
            KernovaLogger.forwardingSink = nil
        }

        var messages: [String] { lock.withLock { recorded } }

        /// The records a refused verb leaves.
        var refusals: [String] { messages.filter { $0.hasPrefix("Refused ") } }

        /// The records a change of another copy's hold leaves.
        var holdTransitions: [String] {
            messages.filter {
                $0.hasPrefix("Found '\(vmName)' held by another copy")
                    || $0.hasPrefix("Another copy of Kernova no longer holds")
            }
        }
    }

    private static func uniqueName(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    @Test("A refused set records one refusal, naming the verb, and the hold it found once")
    func refusedSetRecordsOnce() throws {
        let harness = makeCore()
        let name = Self.uniqueName("Held set")
        let instance = harness.library.registerFixture(name: name)
        harness.store.holdElsewhere(instance.bundleURL)
        let capture = LogCapture(naming: name)
        defer { capture.uninstall() }

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
        let harness = makeCore()
        let name = Self.uniqueName("Held revert")
        let snapshot = VMSnapshot(name: "Only", kind: .cold, macAddress: nil)
        let instance = harness.library.registerFixture(
            name: name, snapshots: VMSnapshotManifest(snapshots: [snapshot]))
        harness.store.holdElsewhere(instance.bundleURL)
        let capture = LogCapture(naming: name)
        defer { capture.uninstall() }

        await #expect(throws: CommandError.self) {
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, takingCheckpoint: false, consent: .all)
        }

        #expect(capture.refusals.count == 1, "\(capture.messages)")
        #expect(capture.refusals.first?.hasPrefix("Refused revertToSnapshot for '\(name)'") == true)
        let uuid = /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/
        #expect(!capture.messages.contains { $0.contains(uuid) }, "\(capture.messages)")
    }

    @Test("A refused delete records one refusal")
    func refusedDeleteRecordsOnce() async throws {
        let harness = makeCore()
        let name = Self.uniqueName("Held delete")
        let instance = harness.library.registerFixture(name: name)
        harness.store.holdElsewhere(instance.bundleURL)
        let capture = LogCapture(naming: name)
        defer { capture.uninstall() }

        await #expect(throws: CommandError.self) {
            try await harness.core.delete(
                .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
        }

        #expect(capture.refusals.count == 1, "\(capture.messages)")
        #expect(capture.refusals.first?.hasPrefix("Refused delete for '\(name)'") == true)
    }

    @Test("A start refused for a twin's identity records one refusal")
    func refusedTwinStartRecordsOnce() async throws {
        let harness = makeCore()
        let name = Self.uniqueName("Twin")
        func twin(_ config: inout VMConfiguration) {
            config.networkEnabled = true
            config.macAddress = Self.sharedMAC
        }
        let source = harness.library.registerFixture(name: Self.uniqueName("Source"), mutate: twin)
        let copy = harness.library.registerFixture(name: name, mutate: twin)
        harness.store.holdElsewhere(source.bundleURL)
        let capture = LogCapture(naming: name)
        defer { capture.uninstall() }

        await #expect(throws: CommandError.self) {
            try await harness.core.start(.id(copy.id), recovery: false, consent: .none)
        }

        #expect(capture.refusals.count == 1, "\(capture.messages)")
        #expect(capture.refusals.first?.hasPrefix("Refused start for '\(name)'") == true)
    }

    @Test("Only a change of another copy's hold is recorded, not a probe that finds it unchanged")
    func unchangedHoldRecordsNothing() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let name = Self.uniqueName("Probed")
        let instance = library.registerFixture(name: name)
        let capture = LogCapture(naming: name)
        defer { capture.uninstall() }

        storage.files.holdElsewhere(instance.bundleURL)
        library.refreshFromOtherCopies()
        library.refreshFromOtherCopies()
        #expect(capture.holdTransitions == ["Found '\(name)' held by another copy of Kernova"])

        storage.files.releaseElsewhere(instance.bundleURL)
        library.refreshFromOtherCopies()
        library.refreshFromOtherCopies()
        #expect(capture.holdTransitions.count == 2, "\(capture.messages)")
        #expect(capture.holdTransitions.last == "Another copy of Kernova no longer holds '\(name)'")
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
        try VMStagedBundle.fixtureForTesting(at: instance.bundleURL, access: harness.store)
            .update(.hostState) { $0.applyEphemeralMode(enabled: true, baseline: snapshot.id) }
        #expect(!instance.hostState.ephemeralModeEnabled)

        await #expect(
            throws: CommandError.invalidArgument(
                VMCommandCore.ephemeralBaselineDeleteRefusal(snapshot, on: instance))
        ) {
            try await harness.core.deleteSnapshot(
                .id(instance.id), snapshot: snapshot.id, consent: Consent([.deleteSnapshot]))
        }

        #expect(instance.ephemeralBaselineSnapshot?.id == snapshot.id)
        #expect(instance.snapshotManifest.snapshots.map(\.id) == [snapshot.id])
        #expect(harness.store.manifest(at: instance.bundleURL)?.snapshots.map(\.id) == [snapshot.id])
        #expect(harness.machineFiles.discardedIDs.isEmpty)
    }

    // MARK: - Harness

    private struct CoreHarness {
        let core: VMCommandCore
        let library: VMLibrary
        let store: InMemoryVMBundleFiles
        let machineFiles: MockVMBundleMachineFiles
        let preferences: AppPreferences
    }

    private func makeCore() -> CoreHarness {
        let storage = MockVMStorageService()
        let fileSystem = MockFileSystem()
        let preferences = makeTestPreferences()
        let lifecycle = makeTestLifecycle(fileSystem: fileSystem)
        let machineFiles = MockVMBundleMachineFiles(files: storage.files)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: machineFiles, lifecycle: lifecycle, fileSystem: fileSystem,
            preferences: preferences)
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem,
            preferences: preferences)
        return CoreHarness(
            core: core, library: library, store: storage.files, machineFiles: machineFiles,
            preferences: preferences)
    }
}
