import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// A create, clone or import as the command core runs it: an arrival that is
/// no VM, whose outcome belongs to the call that waits on it — or, with nobody
/// waiting, to the unattended failure hook — and whose cancel is decided
/// before its rename.
@Suite("VMCommandCore arrivals", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreArrivalTests {
    private let preferences = makeTestPreferences()
    private let storage = MockVMStorageService()
    private let scratch = TestScratchDirectory(prefix: "ArrivalTests")

    private typealias Harness = WiredCommandCore.Scripted<MockVirtualizationService>

    /// Every `.failure` event the core emitted.
    private final class EventLog {
        var failures: [(id: UUID, message: String)] = []
        let changed = AsyncGate()
    }

    private func makeHarness() -> Harness {
        Harness(
            WiredCommandCore(
                virtualization: MockVirtualizationService(), storage: storage, preferences: preferences))
    }

    private func makeSource(in harness: Harness) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: "Source", phase: .stopped, guestOS: .linux, library: harness.library,
            preferences: preferences)
    }

    /// Collects every `.failure` event from here on.
    private func recordFailureEvents(of core: VMCommandCore) -> (EventLog, Task<Void, Never>) {
        let log = EventLog()
        let stream = core.events()
        let task = Task {
            for await batch in stream {
                for case .failure(let id, _, let message) in batch {
                    log.failures.append((id, message))
                }
                log.changed.notify()
            }
        }
        return (log, task)
    }

    /// A bundle whose configuration reads, at a path with nothing on disk to
    /// copy — an import of it fails in the copy.
    private func unreadableSource() -> URL {
        let url = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Vanished.\(VMBundleFormat.fileExtension)", isDirectory: true)
        storage.files.seed(
            VMConfiguration(
                name: "Vanished", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize),
            hostState: VMHostState(), snapshots: VMSnapshotManifest(),
            pairings: USBAccessoryPairingSet(), at: url)
        return url
    }

    // MARK: - One Report per Failure

    @Test("A failed import with a waiter throws to the waiter and never reaches the report hook")
    func failedImportWithAWaiterThrowsToTheWaiterAndNeverReports() async throws {
        let harness = makeHarness()
        let (events, recording) = recordFailureEvents(of: harness.core)
        defer { recording.cancel() }

        await #expect(throws: CommandError.self) {
            try await harness.core.importVM(from: unreadableSource(), waitForOutcome: true)
        }

        #expect(harness.failures.isEmpty)
        #expect(harness.library.entries.isEmpty)
        // Recorded as an event all the same: the event stream observes the
        // library, whoever the failure is reported to.
        try await events.changed.wait { events.failures.count == 1 }
    }

    @Test("An import whose source holds an unreadable file names that file in the source, never the staging directory")
    func importOfUnreadableSourceFileNamesTheSourceFile() async throws {
        let harness = makeHarness()
        let (events, recording) = recordFailureEvents(of: harness.core)
        defer { recording.cancel() }
        let source = scratch.url.appendingPathComponent(
            "Locked.\(VMBundleFormat.fileExtension)", isDirectory: true)
        let disk = source.appendingPathComponent("Disk.asif")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: disk)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: disk.path)
        storage.files.seed(
            VMConfiguration(
                name: "Locked", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize),
            hostState: VMHostState(), snapshots: VMSnapshotManifest(),
            pairings: USBAccessoryPairingSet(), at: source)

        let thrown = await #expect(throws: CommandError.self) {
            try await harness.core.importVM(from: source, waitForOutcome: true)
        }

        let failure = try #require(thrown)
        #expect(failure.alertTitle == "Couldn\u{2019}t Import \u{201C}Locked\u{201D}")
        #expect(
            failure.message
                == "\u{201C}Disk.asif\u{201D} in \u{201C}\(NSString.path(withComponents: source.pathComponents))\u{201D} could not be copied: Permission denied."
        )
        let staged = try #require(storage.stagedBundleURLs.first)
        #expect(!failure.message.contains(staged.lastPathComponent))
        #expect(!failure.message.contains(".Staging"))
        try await events.changed.wait { events.failures.count == 1 }
        #expect(events.failures.first?.message == failure.message)
    }

    // MARK: - Sources Whose Files Have Repairs

    /// A value no field of any config type takes.
    private static let unrecognized = "plan9-mode"

    /// What a copy the library can't read for its `config.json`'s
    /// unrecognized `$.networkMode` says, in the VM named `name`.
    private static func unreadableCopyMessage(_ name: String) -> String {
        "\u{201C}\(name)\u{201D} is in the library, but Kernova can\u{2019}t read \u{201C}config.json\u{201D}: "
            + "$.networkMode: \u{201C}plan9-mode\u{201D} is not a recognized value. "
            + "Choose File > Check Config Files\u{2026} to review it."
    }

    /// What a hook running inside the library's work saw, read back after.
    private final class Captured<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Writes the JSON file at `relativePath` in the bundle at `url` again,
    /// with `edit` applied to what it held — nothing, where there was no file.
    private func editJSON(
        _ relativePath: String, in url: URL, _ edit: (inout [String: Any]) -> Void
    ) throws {
        let fileURL = url.appendingPathComponent(relativePath)
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL) {
            object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        edit(&object)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: fileURL)
    }

    /// An import source named `name` on disk whose `config.json` holds an
    /// unrecognized `$.networkMode`, a problem with a repair.
    private func repairableSource(_ name: String) throws -> (url: URL, id: UUID) {
        let source = try scratch.importSource(name: name)
        try editJSON(VMBundleLayout.configRelativePath, in: source.url) { $0["networkMode"] = Self.unrecognized }
        return (source.url, source.config.id)
    }

    /// Every regular file under `url`, by its path below it.
    private func contents(of url: URL) throws -> [String: Data] {
        let root = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let enumerator = try #require(
            FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        for case let file as URL in enumerator
        where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let path = file.resolvingSymlinksInPath().path(percentEncoded: false)
            files[String(path.dropFirst(root.count))] = try Data(contentsOf: file)
        }
        return files
    }

    @Test(
        "A waited import of a repairable config.json throws; its copy is a row the check lists and repairs to the VM"
    )
    func waitedImportOfARepairableConfigLeavesARowTheCheckRepairs() async throws {
        let harness = makeHarness()
        let source = try repairableSource("Dev")
        let before = try contents(of: source.url)

        let thrown = await #expect(throws: CommandError.self) {
            try await harness.core.importVM(from: source.url, waitForOutcome: true)
        }

        #expect(thrown?.message == Self.unreadableCopyMessage("Dev"))
        #expect(harness.library.entries.count == 1)
        let row = try #require(harness.library.entries.first?.unreadable)
        let destination = try storage.vmsDirectory.appendingPathComponent(
            "Dev.\(VMBundleFormat.fileExtension)", isDirectory: true)
        #expect(harness.library.isSameBundle(row.bundleURL, destination))
        let checked = try await harness.library.checkConfigFiles()
        #expect(checked.count == 1)
        guard case .bundle(let checkedBundle, .configuration)? = checked.first?.location else {
            Issue.record("the check listed \(checked.map(\.location)), not the copy's config.json")
            return
        }
        #expect(harness.library.isSameBundle(checkedBundle, destination))
        #expect(checked.allSatisfy { $0.isRepairable })
        let after = try contents(of: source.url)
        #expect(after == before)

        #expect(await harness.library.useDefaults(in: checked).isEmpty)

        #expect(harness.library.instances.map(\.id) == [source.id])
        #expect(harness.library.entries.count == 1)
        let afterRepair = try contents(of: source.url)
        #expect(afterRepair == before)
    }

    @Test("An unawaited import of a repairable config.json raises no alert, asks for the check, and emits its failure")
    func unawaitedImportOfARepairableConfigAsksForTheCheck() async throws {
        let harness = makeHarness()
        let checkRequests = Captured(0)
        harness.library.onUnreadableFilesFound = { checkRequests.value += 1 }
        let (events, recording) = recordFailureEvents(of: harness.core)
        defer { recording.cancel() }
        let source = try repairableSource("Dev")

        let started = try await harness.core.importVM(from: source.url, waitForOutcome: false)
        let arrival = try #require(harness.library.arrivals.first)
        #expect(await arrival.settle() == nil)

        #expect(harness.failures.isEmpty)
        #expect(checkRequests.value == 1)
        #expect(harness.library.entries.compactMap(\.unreadable).count == 1)
        try await events.changed.wait { events.failures.count == 1 }
        #expect(events.failures.first?.id == started.id)
        #expect(events.failures.first?.message == Self.unreadableCopyMessage("Dev"))
    }

    @Test("A copy the library can't read takes its arrival's selection and its place in the saved order")
    func anUnreadableCopyTakesItsArrivalsSelectionAndPlace() async throws {
        let harness = makeHarness()
        let library = harness.library
        let first = RegisteredVMInstanceFixture.register(
            name: "First", phase: .stopped, guestOS: .linux, library: library, preferences: preferences)
        let last = RegisteredVMInstanceFixture.register(
            name: "Last", phase: .stopped, guestOS: .linux, library: library, preferences: preferences)
        let source = try repairableSource("Dev")

        let started = try await harness.core.importVM(from: source.url, waitForOutcome: false)
        let arrival = try #require(library.arrivals.first)
        let slot = try #require(library.entries.firstIndex { $0.id == started.id })
        let target = try #require(library.entries.firstIndex { $0.id == first.id }) + 1
        library.moveEntries(fromOffsets: IndexSet(integer: slot), toOffset: target)
        #expect(preferences.vmOrder == [first.id, started.id, last.id])
        #expect(library.selectedID == started.id)
        #expect(await arrival.settle() == nil)

        let row = try #require(library.entries.compactMap(\.unreadable).first)
        #expect(library.selectedID == row.id)
        #expect(preferences.vmOrder == [first.id, row.id, last.id])
    }

    /// A core file of a bundle: one an import admits only when it reads, or
    /// when each of its problems has a repair.
    enum CoreFile: CaseIterable, Sendable {
        case configuration, hostState, snapshotManifest
    }

    @Test(
        "A source whose config.json, host state or manifest has a problem with no repair is refused before anything is staged",
        arguments: CoreFile.allCases)
    func aSourceWithAnUnrepairableCoreFileIsRefusedBeforeStaging(_ file: CoreFile) async throws {
        let harness = makeHarness()
        let source = try scratch.importSource(name: "Broken")
        let fileName: String
        switch file {
        case .configuration:
            try editJSON(VMBundleLayout.configRelativePath, in: source.url) { $0["id"] = "not-a-uuid" }
            fileName = "config.json"
        case .hostState:
            try Data("not json".utf8).write(
                to: source.url.appendingPathComponent(VMBundleLayout.hostStateRelativePath))
            fileName = "host-state.json"
        case .snapshotManifest:
            let manifest = source.url.appendingPathComponent(VMBundleLayout.snapshotManifestRelativePath)
            try FileManager.default.createDirectory(
                at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: manifest)
            fileName = "manifest.json"
        }

        let thrown = await #expect(throws: CommandError.self) {
            try await harness.core.importVM(from: source.url, waitForOutcome: true)
        }

        #expect(thrown?.message.hasPrefix("\u{201C}\(fileName)\u{201D} could not be read: ") == true)
        #expect(storage.stagedBundleURLs.isEmpty)
        #expect(harness.library.entries.isEmpty)
    }

    @Test("A repairable host state imports as a VM, its copy's host state readable and arrived as a copy's")
    func importOfARepairableHostStateArrivesAsACopy() async throws {
        let harness = makeHarness()
        let source = try scratch.importSource(name: "Marked")
        var marked = VMHostState()
        marked.startsAutomaticallyOnLaunch = true
        marked.lastRunAt = Date(timeIntervalSince1970: 1_800_000_000)
        let encoded = try VMConfiguration.makeJSONEncoder().encode(marked)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["displayPreference"] = Self.unrecognized
        #expect(object["startsAutomaticallyOnLaunch"] as? Bool == true)
        #expect(object["lastRunAt"] != nil)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: source.url.appendingPathComponent(VMBundleLayout.hostStateRelativePath))
        let before = try contents(of: source.url)

        let summary = try await harness.core.importVM(from: source.url, waitForOutcome: true)

        let imported = try #require(harness.library.instances.first)
        #expect(imported.id == summary.id)
        let copy = try VMBundleFiles(url: imported.bundleURL, access: CoordinatedBundleFileAccess()).read()
        #expect(copy.hostState.startsAutomaticallyOnLaunch == false)
        #expect(copy.hostState.lastRunAt == nil)
        #expect(copy.hostState.displayPreference == .inline)
        let after = try contents(of: source.url)
        #expect(after == before)
    }

    @Test(
        "Importing a symbolic link to a bundle copies the bundle it resolves to, leaving the source's host state as it was"
    )
    func importOfASymlinkCopiesTheBundleItResolvesTo() async throws {
        let harness = makeHarness()
        let source = try scratch.importSource(name: "Linked")
        try VMStagedBundle.fixtureForTesting(at: source.url, access: CoordinatedBundleFileAccess())
            .update(.hostState) { $0.startsAutomaticallyOnLaunch = true }
        let link = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Alias.\(VMBundleFormat.fileExtension)", isDirectory: false)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.url)
        let sourceHostState = source.url.appendingPathComponent(VMBundleLayout.hostStateRelativePath)
        let hostStateBefore = try Data(contentsOf: sourceHostState)
        let filesBefore = try contents(of: source.url)

        let summary = try await harness.core.importVM(from: link, waitForOutcome: true)

        let imported = try #require(harness.library.instances.first { $0.id == summary.id })
        let published = imported.bundleURL
        #expect(published.lastPathComponent == "Linked.\(VMBundleFormat.fileExtension)")
        let values = try published.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        #expect(values.isSymbolicLink == false)
        #expect(values.isDirectory == true)
        #expect(try Set(contents(of: published).keys) == Set(filesBefore.keys))
        #expect(try Data(contentsOf: sourceHostState) == hostStateBefore)
        let copy = try VMBundleFiles(url: published, access: CoordinatedBundleFileAccess()).read()
        #expect(copy.hostState.startsAutomaticallyOnLaunch == false)
    }

    @Test("Importing the source of a bundle the library can't read copies nothing, and answers that row and its file")
    func importingTheSourceOfAnUnreadableRowCopiesNothing() async throws {
        let harness = makeHarness()
        let source = try scratch.importSource(name: "Dev")
        let libraryCopy = try storage.vmsDirectory.appendingPathComponent(
            "Dev.\(VMBundleFormat.fileExtension)", isDirectory: true)
        try FileManager.default.copyItem(at: source.url, to: libraryCopy)
        try editJSON(VMBundleLayout.configRelativePath, in: libraryCopy) { $0["networkMode"] = Self.unrecognized }
        await harness.library.loadVMs()
        let row = try #require(harness.library.entries.first?.unreadable)
        harness.library.selection = nil

        let thrown = await #expect(throws: CommandError.self) {
            try await harness.core.importVM(from: source.url, waitForOutcome: true)
        }
        let batch = harness.core.beginImports(from: [source.url], intoFolder: nil)

        #expect(thrown?.message == Self.unreadableCopyMessage("Dev"))
        #expect(batch.imports.count == 1)
        guard case .failure(let refusal)? = batch.imports.first else {
            Issue.record("the batch answered \(batch.imports), not a refusal")
            return
        }
        #expect((refusal as? CommandError)?.message == Self.unreadableCopyMessage("Dev"))
        #expect(harness.library.selectedID == row.id)
        #expect(storage.stagedBundleURLs.isEmpty)
        #expect(harness.library.entries.count == 1)
    }

    @Test("A reconcile between the rename and the arrival's step leaves an unreadable copy to the arrival: one row")
    func aReconcileDuringTheRenameLeavesAnUnreadableCopyToItsArrival() async throws {
        let harness = makeHarness()
        let library = harness.library
        let source = try repairableSource("Dev")
        let reconciled = Captured<[LibraryEntry]>([])

        _ = await storage.withAfterPublish({
            library.reconcileWithDisk()
            reconciled.value = library.entries
        }) {
            await #expect(throws: CommandError.self) {
                try await harness.core.importVM(from: source.url, waitForOutcome: true)
            }
        }

        #expect(reconciled.value.count == 1)
        #expect(reconciled.value.first?.arrival != nil)
        #expect(library.entries.count == 1)
        #expect(library.entries.first?.unreadable != nil)
    }

    @Test("A cancel during the rename of an unreadable copy whose trash fails keeps its row and reports once")
    func aCancelDuringTheRenameOfAnUnreadableCopyWhoseTrashFailsKeepsItsRow() async throws {
        let harness = makeHarness()
        let source = try repairableSource("Dev")
        let hold = DispatchSemaphore(value: 0)
        storage.setPublishHold(hold)
        storage.setDeleteVMBundleError(CocoaError(.fileWriteNoPermission))

        let started = try await harness.core.importVM(from: source.url, waitForOutcome: false)
        let arrival = try #require(harness.library.arrivals.first)
        try await storage.publishLanded.wait { storage.publishBundleCallCount == 1 }
        try harness.core.cancelPreparing(.id(started.id), consent: .all)
        hold.signal()

        #expect(await arrival.settle() == nil)
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(harness.library.arrivals.isEmpty)
        #expect(harness.library.entries.count == 1)
        #expect(harness.library.entries.first?.unreadable != nil)
        #expect(harness.failures.count == 1)
    }

    // MARK: - An Arrival Is Not a VM

    @Test("An arrival's storage disks answer the list its write was asked for, unmeasured")
    func storageDisksOfAnArrivalAreUnmeasured() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let hold = DispatchSemaphore(value: 0)
        storage.setCloneHold(hold)
        defer { hold.signal() }

        let row = try await harness.core.clone(
            .id(source.id), outcome: .newMachine, waitForOutcome: false)
        let arrival = try #require(harness.library.arrivals.first)

        let disks = try await harness.core.storageDisks(of: .id(row.id))

        #expect(disks.map(\.label) == ["Main Disk"])
        #expect(
            disks.map(\.path)
                == [arrival.destinationURL.appendingPathComponent("Disk.asif").path(percentEncoded: false)])
        #expect(disks.allSatisfy { $0.capacityBytes == nil && $0.usedBytes == nil })
        hold.signal()
        await arrival.settle()
    }

    // MARK: - Cancel Around the Rename

    @Test("A cancel during the rename of a create that starts after creating trashes it and starts nothing")
    func aCancelDuringPublishingOfAStartingCreateTrashesItAndStartsNothing() async throws {
        let harness = makeHarness()
        let hold = DispatchSemaphore(value: 0)
        storage.setPublishHold(hold)
        let configuration = VMConfiguration(
            name: "Withdrawn", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let destination = try storage.bundleURL(for: configuration)

        let row = try harness.core.create(
            configuration: configuration, diskSizeInGB: 64,
            startAfterCreate: true, guestAccountPassword: nil)
        let arrival = try #require(harness.library.arrivals.first)
        try await storage.publishLanded.wait { storage.publishBundleCallCount == 1 }
        #expect(arrival.stage == .publishing)

        try harness.core.cancelPreparing(.id(row.id), consent: .all)
        #expect(arrival.stage == .withdrawing)
        #expect(arrival.displayLabel == "Cancelling\u{2026}")
        hold.signal()

        // The auto-start chains off a VM the outcome delivers, and the outcome
        // is the cancel.
        await #expect(throws: CancellationError.self) { try await arrival.settled.value }
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(storage.bundleIdentity(at: destination) == nil)
        #expect(harness.library.entries.isEmpty)
        #expect(harness.virtualization.startCallCount == 0)
        #expect(harness.failures.isEmpty)
    }

    @Test("A waiter on an arrival cancelled during its rename receives the cancel, not the VM")
    func aWaiterOnAnArrivalCancelledDuringItsRenameReceivesTheCancel() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let hold = DispatchSemaphore(value: 0)
        storage.setPublishHold(hold)

        let waiter = Task {
            try await harness.core.clone(.id(source.id), outcome: .newMachine, waitForOutcome: true)
        }
        try await storage.publishLanded.wait { storage.publishBundleCallCount == 1 }
        let arrival = try #require(harness.library.arrivals.first)
        try harness.core.cancelPreparing(.id(arrival.id), consent: .all)
        hold.signal()

        let error = try await #require(throws: CommandError.self) { try await waiter.value }
        guard case .operationFailed(_, _, let message, _) = error else {
            Issue.record("expected the clone's cancel, got \(error)")
            return
        }
        #expect(message == "The clone was cancelled.")
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(harness.library.instances.map(\.id) == [source.id])
        #expect(harness.failures.isEmpty)
    }

    @Test("A cancel during the rename whose trash fails keeps the VM and reports the failure once")
    func aCancelDuringTheRenameWhoseTrashFailsKeepsTheVM() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let hold = DispatchSemaphore(value: 0)
        storage.setPublishHold(hold)
        storage.setDeleteVMBundleError(CocoaError(.fileWriteNoPermission))

        let row = try await harness.core.clone(
            .id(source.id), outcome: .newMachine, waitForOutcome: false)
        let arrival = try #require(harness.library.arrivals.first)
        try await storage.publishLanded.wait { storage.publishBundleCallCount == 1 }

        try harness.core.cancelPreparing(.id(row.id), consent: .all)
        hold.signal()

        // The bundle the Trash turned down is still in the VMs directory, so
        // it is the VM it now is, and nothing follows the arrival with it.
        #expect(await arrival.settle() == nil)
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(Set(harness.library.instances.map(\.id)) == [source.id, row.id])
        #expect(harness.library.arrivals.isEmpty)
        #expect(harness.failures.count == 1)
    }

    @Test("A cancel that arrives after adoption is refused and deletes nothing")
    func aCancelAfterAdoptionIsRefusedAndDeletesNothing() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let clone = try await harness.core.clone(
            .id(source.id), outcome: .newMachine, waitForOutcome: true)
        #expect(clone.status == VMStatus.stopped.rawValue)

        let refusal = try #require(throws: CommandError.self) {
            try harness.core.cancelPreparing(.id(clone.id), consent: .all)
        }
        guard case .invalidState = refusal else {
            Issue.record("expected an invalid-state refusal, got \(refusal)")
            return
        }
        #expect(storage.deleteVMBundleCallCount == 0)
        #expect(Set(harness.library.instances.map(\.id)) == [source.id, clone.id])
    }

    // MARK: - The MAC Address Follows the Machine Identity

    /// The configuration of the clone of a source carrying `mac`, with its
    /// device on or off, taken as `outcome`.
    private func clonedConfiguration(
        ofSourceWith mac: String?, networkEnabled: Bool, outcome: CloneOutcome?
    ) async throws -> VMConfiguration {
        let harness = makeHarness()
        let source = RegisteredVMInstanceFixture.register(
            name: "Source", phase: .stopped, guestOS: .linux, library: harness.library,
            preferences: preferences
        ) {
            $0.networkEnabled = networkEnabled
            $0.macAddress = mac
        }
        let row = try await harness.core.clone(
            .id(source.id), outcome: outcome, waitForOutcome: true)
        let clone = try #require(harness.library.instances.first { $0.id == row.id })
        return clone.configuration
    }

    @Test("An Exact Copy keeps the source's MAC address")
    func exactCopyKeepsMACAddress() async throws {
        let config = try await clonedConfiguration(
            ofSourceWith: "aa:bb:cc:dd:ee:01", networkEnabled: true, outcome: .exactCopy)
        #expect(config.macAddress == "aa:bb:cc:dd:ee:01")
    }

    @Test("A New Machine gets a fresh MAC address")
    func newMachineGetsFreshMACAddress() async throws {
        let config = try await clonedConfiguration(
            ofSourceWith: "aa:bb:cc:dd:ee:01", networkEnabled: true, outcome: .newMachine)
        let mac = try #require(config.macAddress)
        #expect(mac != "aa:bb:cc:dd:ee:01")
        #expect(GuestMACAddress.normalized(mac) == mac)
    }

    @Test("A New Machine of a macOS guest gets its own machine identifier")
    func newMachineOfAMacOSGuestGetsItsOwnMachineIdentifier() async throws {
        let harness = makeHarness()
        let source = RegisteredVMInstanceFixture.register(
            name: "Source", phase: .stopped, guestOS: .macOS, library: harness.library,
            preferences: preferences
        ) {
            $0.machineIdentifierData = Data("source machine identifier".utf8)
        }
        let row = try await harness.core.clone(
            .id(source.id), outcome: .newMachine, waitForOutcome: true)
        let clone = try #require(harness.library.instances.first { $0.id == row.id })
        let identity = try #require(clone.machineIdentity)
        #expect(identity != source.machineIdentity)
    }

    @Test("A New Machine of a networked source with no address gets one")
    func newMachineOfNetworkedAddresslessSourceGetsOne() async throws {
        let config = try await clonedConfiguration(
            ofSourceWith: nil, networkEnabled: true, outcome: .newMachine)
        #expect(config.macAddress != nil)
    }

    @Test("An explicit New Machine of a guest running macOS 12 is refused, and nothing is copied")
    func newMachineOfAMontereyGuestIsRefused() throws {
        let harness = makeHarness()
        let source = RegisteredVMInstanceFixture.register(
            name: "Monterey", phase: .stopped, guestOS: .macOS, library: harness.library,
            preferences: preferences
        ) {
            $0.lastSeenGuestOSVersion = "12.7.6"
        }

        #expect(throws: CommandError.unsupported(capability: "cloning as a New Machine")) {
            try harness.core.beginClone(.id(source.id), outcome: .newMachine)
        }
        #expect(harness.library.entries.map(\.id) == [source.id])
    }

    // MARK: - A Clone of a Suspended or Live VM

    private func register(
        _ phase: VMLifecyclePhase, in harness: Harness,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: "Source", phase: phase, guestOS: .linux, library: harness.library,
            preferences: preferences, mutate: mutate)
    }

    @Test("An Exact Copy keeps the version that wrote each saved state it carries")
    func exactCopyKeepsEachSavedStatesVersion() async throws {
        let harness = makeHarness()
        let snapshot = VMSnapshot(name: "Warm", kind: .warm, macAddress: nil)
        let source = RegisteredVMInstanceFixture.register(
            name: "Source", phase: .suspended, guestOS: .linux, snapshots: [snapshot],
            library: harness.library, preferences: preferences)
        try VMInstanceFixture.writeSaveFile(for: source)
        try SavedStateVersion.record("0.9.0 (300)", at: source.bundleLayout.saveFileURL)
        let captured = source.bundleLayout.snapshotLayout(id: snapshot.id).saveFileURL
        try FileManager.default.createDirectory(
            at: captured.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("captured-state".utf8).write(to: captured)
        try SavedStateVersion.record("0.8.0 (200)", at: captured)

        let row = try await harness.core.clone(
            .id(source.id), outcome: .exactCopy, waitForOutcome: true)

        let clone = try #require(harness.library.instances.first { $0.id == row.id })
        #expect(clone.phase == .suspended)
        #expect(clone.savedStateVersion == "0.9.0 (300)")
        #expect(clone.savedStateVersion(ofSnapshot: snapshot.id) == "0.8.0 (200)")
    }

    /// The bundle files `source`'s saved state restores onto — what a live
    /// copy takes inside its pause.
    private func stateBoundPaths(of source: VMInstance) -> [String] {
        VMBundleItems.capturedRelativePaths(
            for: source.configuration, layout: source.bundleLayout)
    }

    @Test(
        "A live clone copies its settled files before the pause, and only what its saved state restores onto inside it",
        arguments: [CloneOutcome.exactCopy, .newMachine])
    func liveCloneCopiesOnlyStateBoundFilesInsideThePause(outcome: CloneOutcome) async throws {
        let harness = makeHarness()
        let sessionID = UUID()
        let source = register(.running(sessionID: sessionID), in: harness)
        let session = MockSnapshotSession(guestState: .running, writesStateFile: true)
        harness.virtualization.liveCopySession = session
        let hold = DispatchSemaphore(value: 0)
        storage.setCloneHold(hold)

        let waiter = Task {
            try await harness.core.clone(.id(source.id), outcome: outcome, waitForOutcome: true)
        }
        // The settled files go first, with the guest untouched.
        try await storage.cloneEntered.wait { storage.cloneVMBundleCallCount == 1 }
        #expect(await session.calls.isEmpty)
        let settled = storage.lastCloneRelativePaths ?? []
        #expect(settled.contains(VMBundleLayout.hardwareModelRelativePath))
        #expect(Set(settled).isDisjoint(with: stateBoundPaths(of: source)))
        hold.signal()
        // The files the saved state restores onto copy while the guest is
        // paused on the state just written, and nothing else does.
        try await storage.cloneEntered.wait { storage.cloneVMBundleCallCount == 2 }
        #expect(await session.calls == ["pauseIfRunning", "saveMachineState"])
        #expect(await session.guestState == .paused)
        #expect(storage.lastCloneRelativePaths == stateBoundPaths(of: source))
        #expect(source.status == .cloning)
        hold.signal()
        let row = try await waiter.value

        #expect(await session.calls == ["pauseIfRunning", "saveMachineState", "resumeIfPaused"])
        #expect(await session.guestState == .running)
        #expect(source.phase == .running(sessionID: sessionID))
        let clone = try #require(harness.library.instances.first { $0.id == row.id })
        // Both outcomes save; only an Exact Copy keeps what was saved.
        switch outcome {
        case .exactCopy:
            #expect(clone.phase == .suspended)
            #expect(clone.hasSaveFile)
        case .newMachine:
            #expect(clone.phase == .stopped)
            #expect(!clone.hasSaveFile)
        }
    }
}
