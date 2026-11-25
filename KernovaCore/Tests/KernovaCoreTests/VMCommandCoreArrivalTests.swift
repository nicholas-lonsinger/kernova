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

    // MARK: - Sources Whose Files Have Repairs

    /// A value no field of any config type takes.
    private static let unrecognized = "plan9-mode"

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

        await #expect(throws: CommandError.self) {
            try await harness.core.importVM(from: source.url, waitForOutcome: true)
        }

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

    @Test("An import of a bundle holding a symbolic link is refused")
    func importOfABundleHoldingALinkIsRefused() async throws {
        let harness = makeHarness()
        let source = try scratch.importSource(name: "Linked Disk")
        let moved = scratch.url.appendingPathComponent("\(UUID().uuidString).asif")
        try Data("disk".utf8).write(to: moved)
        try FileManager.default.createSymbolicLink(
            at: VMBundleLayout(bundleURL: source.url).diskImageURL, withDestinationURL: moved)

        await #expect(throws: CommandError.self) {
            try await harness.core.importVM(from: source.url, waitForOutcome: true)
        }

        #expect(harness.library.instances.isEmpty)
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

    // MARK: - Cancel Around the Rename

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

        let error = try await #require(throws: CommandError.self) { try await waiter.joined() }
        guard case .operationFailed(_, _, let message, _) = error else {
            Issue.record("expected the clone's cancel, got \(error)")
            return
        }
        #expect(message == "The clone was cancelled.")
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(harness.library.instances.map(\.id) == [source.id])
        #expect(harness.failures.isEmpty)
    }

    @Test("A cancel that arrives after adoption is refused and deletes nothing")
    func aCancelAfterAdoptionIsRefusedAndDeletesNothing() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let clone = try await harness.core.clone(
            .id(source.id), outcome: .newMachine, waitForOutcome: true)
        #expect(clone.status == .runtime(.stopped))

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

    // MARK: - A Clone of a Suspended or Live VM

    private func register(
        _ phase: VMLifecyclePhase, in harness: Harness,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: "Source", phase: phase, guestOS: .linux, library: harness.library,
            preferences: preferences, mutate: mutate)
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
        let row = try await waiter.joined()

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
