import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization
@testable import KernovaVirtualizationTestSupport

@Suite("VirtualizationService Tests", .caseScoped)
@MainActor
struct VirtualizationServiceTests {
    private let service = VirtualizationService(
        vmnetNetworks: VmnetNetworkService.scripted(), vmnetAttachments: MockVmnetAttachments().maker,
        bridgedInterfaces: MockBridgedInterfaceProvider(), entitlements: .unentitled, guestAgents: .testing,
        isProtectedDataAvailable: { true })
    private let scratch = TestScratchDirectory(prefix: "VirtualizationServiceTests")

    // MARK: - Suspend

    /// Suspends `instance` over `session` inside the save operation the VM
    /// admits.
    private func suspend(_ instance: VMInstance, over session: MockSnapshotSession) async throws {
        try await instance.activity.perform(.saving) { context in
            try await VirtualizationService.save(instance, context, session: session)
        }
    }

    @Test("A suspend whose write throws drops the part-written slot and rests at the failure")
    func suspendFailureDropsThePartWrittenSlot() async throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        let session = MockSnapshotSession(guestState: .running)
        await session.setSaveError(
            NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "The disk is full."]))
        // What VZ wrote in place before the write failed.
        try VMInstanceFixture.writeSaveFile(for: instance)

        let error = await #expect(throws: (any Error).self) {
            try await suspend(instance, over: session)
        }

        #expect(error?.localizedDescription == "The disk is full.")
        #expect(!instance.hasSaveFile)
        #expect(instance.phase == .failed(message: "The disk is full."))
    }

    @Test("A suspend records the Kernova that wrote the slot")
    func suspendRecordsTheVersion() async throws {
        let products = AppBundleProducts(
            bundleURL: AppBundleProducts.testing.bundleURL, hostVersion: "0.10.0", buildNumber: "412",
            guestAgents: .testing)
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()), bundleProducts: products)
        let session = MockSnapshotSession(guestState: .running, writesStateFile: true)

        try await suspend(instance, over: session)

        #expect(instance.phase == .suspended)
        #expect(instance.savedStateVersion == "0.10.0 (412)")
    }

    @Test("A guest that goes away mid-suspend drops the slot and rests where its end put it")
    func suspendOverAVanishingGuestDropsTheSlot() async throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        let session = MockSnapshotSession(guestState: .running)
        await session.setAfterSave {
            await MainActor.run {
                // However far VZ got before the guest went away.
                try? VMInstanceFixture.writeSaveFile(for: instance)
                instance.handleSessionEvent(.guestDidStop)
            }
        }

        try await suspend(instance, over: session)

        #expect(!instance.hasSaveFile)
        // Stopped, not suspended on a slot that cannot restore.
        #expect(instance.phase == .stopped)
    }

    // MARK: - The unsettled-session marker on the production paths

    private struct Probe: Error {}

    private func holdsSpentSlot(_ layout: VMBundleLayout) -> Bool {
        FileManager.default.fileExists(atPath: layout.spentSaveFileURL.path(percentEncoded: false))
    }

    /// Makes `instance`'s bundle directory read-only, so no file in it can be
    /// moved or removed; the returned closure puts its permissions back.
    private static func lockBundleDirectory(of instance: VMInstance) throws -> () -> Void {
        let bundlePath = instance.bundleURL.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundlePath)
        return {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: bundlePath)
        }
    }

    /// What a session's marker read at some moment mid-operation.
    @MainActor
    private final class MarkerRecord {
        var atResume: Bool?
        var settlements = 0
    }

    /// Restores `instance` from its slot over `session` inside the bring-up the
    /// VM admits, through the production restore.
    private func restore(_ instance: VMInstance, over session: MockSnapshotSession) async throws {
        try await instance.activity.launchStartGuest(.restoringSavedState) { context in
            try await VirtualizationService.restoreSavedState(
                instance, context.bringUp.operation, session: session,
                isProtectedDataAvailable: { true })
            context.bringUp.bindSessionForTesting(UUID())
            return .rest(.live(.running), ())
        }.value()
    }

    @Test("A spend the file system refuses keeps the guest from executing")
    func refusedSpendKeepsTheGuestFromExecuting() async throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let session = MockSnapshotSession(guestState: .paused)
        let unlock = try Self.lockBundleDirectory(of: instance)
        defer { unlock() }

        await #expect(throws: (any Error).self) { try await restore(instance, over: session) }

        #expect(!(await session.calls).contains("resume"))
        #expect(instance.hasSaveFile)
        #expect(!instance.hostState.hasUnsettledSession)
        #expect(instance.phase == .suspended)
    }

    @Test("A restore whose bundle Finder moved away, unfollowed, runs no guest and leaves the slot with the bundle")
    func restoreAfterAnUnfollowedMoveRunsNoGuest() async throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let bundleURL = instance.bundleURL
        let moved = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Moved-\(UUID().uuidString).kernova", isDirectory: true)
        let session = MockSnapshotSession(guestState: .paused)
        // Once VZ has loaded the slot, with no rescan to follow the move.
        await session.setAfterRestore {
            try? FileManager.default.moveItem(at: bundleURL, to: moved)
        }

        let error = await #expect(throws: VirtualizationError.self) {
            try await restore(instance, over: session)
        }

        guard case .restoreFailed(let underlying, _)? = error,
            case VirtualizationError.noSaveFile = underlying
        else {
            Issue.record("refused with \(String(describing: error))")
            return
        }
        #expect(!(await session.calls).contains("resume"))
        #expect(VMBundleLayout(bundleURL: moved).hasSaveFile)
    }

    @Test("A session resumed from a slot rests stopped at its end even when the spent slot's removal is refused")
    func refusedSpentSlotRemovalStillRestsStopped() async throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let session = MockSnapshotSession(guestState: .paused)
        let unlock = UnlockBox()
        defer { unlock.run() }
        await session.setBeforeResume {
            await MainActor.run { unlock.action = try? Self.lockBundleDirectory(of: instance) }
        }

        try await restore(instance, over: session)
        unlock.run()
        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.phase == .stopped)
        #expect(!instance.hasSaveFile)
        // Left for the launch pass.
        #expect(holdsSpentSlot(instance.bundleLayout))
    }

    /// The permissions to put back once a test's `setBeforeResume` locked the
    /// bundle directory.
    @MainActor
    private final class UnlockBox {
        var action: (() -> Void)?
        func run() {
            action?()
            action = nil
        }
    }

    @Test("A restore VZ refuses fails before any mark, keeping the slot and the marker as they were")
    func refusedRestoreLeavesTheMarkerAndSlot() async throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let session = MockSnapshotSession(guestState: .paused)
        await session.setRestoreError(Probe())

        await #expect(throws: (any Error).self) { try await restore(instance, over: session) }

        #expect(!(await session.calls).contains("resume"))
        #expect(!instance.hostState.hasUnsettledSession)
        #expect(instance.hasSaveFile)
    }

    @Test("A resume that fails after the mark retracts it, keeping the slot")
    func failedResumeRetractsTheMark() async throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let session = MockSnapshotSession(guestState: .paused)
        await session.setResumeError(Probe())

        await #expect(throws: (any Error).self) { try await restore(instance, over: session) }

        #expect(!instance.hostState.hasUnsettledSession)
        #expect(instance.hasSaveFile)
        #expect(!holdsSpentSlot(instance.bundleLayout))
    }

    @Test("A mark the guest never executed under is retracted to the value it replaced")
    func retractionRestoresThePriorMarker() async throws {
        // Live, so its session is already marked.
        let instance = VMInstanceFixture.make(phase: .livePaused(sessionID: UUID()))
        #expect(instance.hostState.hasUnsettledSession)

        await #expect(throws: Probe.self) {
            try await instance.activity.perform(.resuming) { context in
                try await context.executingGuest { _ in throw Probe() }
                return .rest(.asStarted, ())
            }
        }

        #expect(instance.hostState.hasUnsettledSession)
    }

    @Test("A bring-up's own session takes no live execution until its guest has executed")
    func liveExecutionWaitsForTheGuestToExecute() async throws {
        let instance = VMInstanceFixture.make(phase: .stopped)
        try await instance.activity.launchStartGuest(.starting(recovery: false)) { context in
            context.bringUp.bindSessionForTesting(UUID())
            #expect(throws: (any Error).self) { _ = try context.bringUp.operation.liveExecution() }
            try await context.bringUp.operation.executingGuest { _ in }
            _ = try context.bringUp.operation.liveExecution()
            return .rest(.live(.running), ())
        }.value()
    }

    /// A Linux agent whose disk is written into `scratch`, and a service and products bundling it.
    private func linuxAgentProducts() throws -> (VirtualizationService, AppBundleProducts, GuestAgentDiskCache) {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let agent = scratch.url.appending(path: "kernova-agent")
        try Data(repeating: 0x7F, count: 4096).write(to: agent)
        // This bundle carries none of KernovaCore's resources, so the disk's other files are stand-ins.
        let files = scratch.url.appending(path: "LinuxAgentDisk")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for name in ["agent-disk.sh", "README.txt", "LICENSES.txt"] {
            try Data(name.utf8).write(to: files.appending(path: name))
        }
        let cache = GuestAgentDiskCache(directory: scratch.url.appending(path: "GuestAgentDisks"), files: files)
        // The app's disk, as the agent's first mount leaves it.
        try FileManager.default.createDirectory(
            at: cache.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the app's disk".utf8).write(to: cache.url)
        let products = AppBundleProducts(
            bundleURL: AppBundleProducts.testing.bundleURL, hostVersion: "1.0", buildNumber: "1",
            guestAgents: .linux(agent: agent, disk: cache))
        let service = VirtualizationService(
            vmnetNetworks: VmnetNetworkService.scripted(), vmnetAttachments: MockVmnetAttachments().maker,
            bridgedInterfaces: MockBridgedInterfaceProvider(), entitlements: .unentitled,
            guestAgents: products.guestAgents, isProtectedDataAvailable: { true })
        return (service, products, cache)
    }

    @Test("A cold boot starts without the installer disk the last session had, and drops its copy")
    func coldBootStartsWithoutTheInstallerDisk() async throws {
        let (service, products, cache) = try linuxAgentProducts()
        let library = makeWiredLibrary(bundleProducts: products)
        defer { withExtendedLifetime(library) {} }
        let item = RemovableMediaItem(path: cache.url.path(percentEncoded: false), readOnly: true)
        let instance = library.registerFixture(phase: .stopped) { $0.removableMedia = [item] }
        let copy = instance.bundleLayout.guestAgentDiskCopyURL(for: item)
        try FileManager.default.createDirectory(
            at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the last session's copy".utf8).write(to: copy)

        // The bundle holds no real disk image, so the boot fails at the
        // configuration build, after the configuration is settled.
        await #expect(throws: ConfigurationBuilderError.self) { try await start(instance, on: service) }

        #expect(instance.configuration.removableMedia == nil)
        #expect(!FileManager.default.fileExists(atPath: instance.bundleLayout.guestAgentDiskDirectoryURL.path))
    }

    @Test("A boot that attaches the virtio DMG attaches its own copy of it")
    func virtioBootMakesItsOwnCopy() async throws {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .stopped) {
            $0.installedImage = .macOSRestoreImage(version: "12.0.1", build: "21A559")
        }
        let dmg = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)

        await #expect(throws: (any Error).self) { try await start(instance) }

        let copy = instance.bundleLayout.guestAgentVirtioDiskURL(of: dmg)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: dmg))
    }

    @Test("A cold boot that fails before the guest executes leaves the marker as it was")
    func failedColdBootLeavesTheMarker() async throws {
        let instance = VMInstanceFixture.make(phase: .stopped)

        // The bundle holds no real disk image, so the boot fails at the
        // configuration build, ahead of the start.
        await #expect(throws: (any Error).self) { try await start(instance) }

        #expect(!instance.hostState.hasUnsettledSession)
    }

    @Test("A suspend that completes its slot parks the session, settling it with no session-end rule")
    func completeSuspendParksTheSession() async throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        let record = MarkerRecord()
        instance.activity.onUnsettledSession = {
            record.settlements += 1
            return []
        }
        let session = MockSnapshotSession(guestState: .running, writesStateFile: true)

        try await suspend(instance, over: session)

        #expect(instance.phase == .suspended)
        #expect(!instance.hostState.hasUnsettledSession)
        #expect(record.settlements == 0)
    }

    @Test("A suspend whose guest goes away mid-write parks nothing: its session's end is settled by the rule")
    func suspendLosingItsGuestParksNothing() async throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        let record = MarkerRecord()
        instance.activity.onUnsettledSession = {
            record.settlements += 1
            return []
        }
        let session = MockSnapshotSession(guestState: .running)
        await session.setAfterSave {
            await MainActor.run { instance.handleSessionEvent(.guestDidStop) }
        }

        try await suspend(instance, over: session)

        #expect(instance.phase == .stopped)
        #expect(record.settlements == 1)
    }

    // MARK: - Warm capture over a session that goes away

    /// How an operation's session had ended at some moment mid-operation.
    @MainActor
    private final class SessionEndRecord {
        var end: VMSessionEnd?
    }

    /// Captures `snapshot` from `instance`'s live session inside the capture
    /// operation the VM admits.
    @discardableResult
    private func captureWarm(
        _ instance: VMInstance, snapshot: VMSnapshotCaptureRequest, session: MockSnapshotSession
    ) async throws -> VMSnapshot {
        try await instance.activity.launchedCapture(.live) { context in
            try await VirtualizationService.captureWarmSnapshot(
                instance, context, snapshot: snapshot, session: session)
        }
    }

    @Test("A guest that dies mid-capture leaves the VM where the session's end put it, not running")
    func warmCaptureDoesNotHandTheVMBackToADeadSession() async throws {
        let sessionID = UUID()
        let store = MockVMBundleMachineFiles()
        let instance = VMInstanceFixture.make(
            phase: .running(sessionID: sessionID), bundleFactory: VMBundle.Factory(machineFiles: store))
        let session = MockSnapshotSession(guestState: .running)
        let snapshot = VMSnapshotCaptureRequest(name: "Before the update")
        let whileCapturing = SessionEndRecord()
        // `didStopWithError` lands while the disks copy, exactly as a guest
        // shutdown or a VZ error does — and `resumeIfPaused` returns rather than
        // throwing once the guest is no longer paused, so the capture itself
        // still succeeds.
        await session.setAfterSave {
            await MainActor.run {
                instance.handleSessionEvent(
                    .didStopWithError(
                        NSError(
                            domain: "test", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "The guest stopped."])))
                whileCapturing.end = instance.phase.operation?.sessionEnd
            }
        }

        try await captureWarm(instance, snapshot: snapshot, session: session)

        // The capture kept holding the VM: the session's end only marked it.
        #expect(whileCapturing.end == .stoppedWithError(message: "The guest stopped."))
        // The snapshot is complete — its state and disks were both written
        // before the guest went away — so the caller records it.
        #expect(store.capturedPaths[snapshot.id] != nil)
        // And the VM rests where the session's end put it rather than claiming
        // a session nothing holds.
        #expect(instance.status == .error)
        #expect(!instance.hasLiveVirtualMachine)
        #expect(instance.activity.decide(.start(recovery: false), posture: .commit) == .admit)
        #expect(instance.activity.decide(.sessionAction(.requestStop), posture: .commit) != .admit)
    }

    @Test("A capture that keeps its session hands the VM back to it")
    func warmCaptureRestoresTheRunningPhase() async throws {
        let sessionID = UUID()
        let store = MockVMBundleMachineFiles()
        let instance = VMInstanceFixture.make(
            phase: .running(sessionID: sessionID), bundleFactory: VMBundle.Factory(machineFiles: store))
        let session = MockSnapshotSession(guestState: .running)

        let captured = try await captureWarm(
            instance, snapshot: VMSnapshotCaptureRequest(name: "Before the update"), session: session)

        #expect(captured.kind == .warm)
        #expect(instance.phase == .running(sessionID: sessionID))
    }

    @Test("A warm snapshot carries the VM's copy of the installer disk with its other files")
    func warmSnapshotCarriesTheInstallerCopy() async throws {
        let store = MockVMBundleMachineFiles()
        let library = makeWiredLibrary(machineFiles: store)
        let sessionID = UUID()
        let path = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL).path(percentEncoded: false)
        let installer = RemovableMediaItem(path: path, readOnly: true)
        let instance = library.registerFixture(guestOS: .macOS, phase: .running(sessionID: sessionID)) {
            $0.removableMedia = [installer]
        }
        instance.beginSessionContextForTesting()
        try await GuestAgentDiskCopies.make(
            of: URL(filePath: path), at: instance.bundleLayout.guestAgentDiskCopyURL(for: installer))

        let captured = try await captureWarm(
            instance, snapshot: VMSnapshotCaptureRequest(name: "With the disk"),
            session: MockSnapshotSession(guestState: .running))

        #expect(store.capturedPaths[captured.id]?.contains(VMBundleLayout.guestAgentDiskRelativePath) == true)
        #expect(store.capturedConfiguration(for: captured.id)?.removableMedia == [installer])
        // The guest keeps its disk: the capture neither detached nor moved it.
        #expect(instance.configuration.removableMedia == [installer])
    }

    @Test("A capture of a live-paused guest hands it back live-paused")
    func warmCaptureRestoresTheLivePausedPhase() async throws {
        let sessionID = UUID()
        let store = MockVMBundleMachineFiles()
        let instance = VMInstanceFixture.make(
            phase: .livePaused(sessionID: sessionID), bundleFactory: VMBundle.Factory(machineFiles: store))
        let session = MockSnapshotSession(guestState: .paused)

        try await captureWarm(instance, snapshot: VMSnapshotCaptureRequest(name: "Paused"), session: session)

        #expect(instance.phase == .livePaused(sessionID: sessionID))
    }

    @Test("A failed capture puts a running guest back")
    func warmCaptureFailureRestsWhereTheGuestIs() async throws {
        let sessionID = UUID()
        let store = MockVMBundleMachineFiles()
        let instance = VMInstanceFixture.make(
            phase: .running(sessionID: sessionID), bundleFactory: VMBundle.Factory(machineFiles: store))
        let session = MockSnapshotSession(guestState: .running)
        store.setCaptureError(VMSnapshotError.snapshotMissingSavedState)

        await #expect(throws: VMSnapshotError.self) {
            try await captureWarm(
                instance, snapshot: VMSnapshotCaptureRequest(name: "Doomed"), session: session)
        }

        #expect(instance.phase == .running(sessionID: sessionID))
    }

    // MARK: - Snapshot revert

    /// A bundle holding one snapshot's captured disk, saved state and
    /// configuration, plus the VM's own files.
    private struct RevertFixture {
        let instance: VMInstance
        let snapshot: VMSnapshot
        /// Holds the instance, as the library a revert hands the written
        /// configuration to.
        let library: VMLibrary
    }

    private func makeRevertFixture(phase: VMLifecyclePhase = .stopped) throws -> RevertFixture {
        let snapshot = VMSnapshot(name: "Before the update", kind: .warm, macAddress: nil)
        let library = makeWiredLibrary(
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()))
        let instance = try library.registerOnDiskFixture(
            name: "Revert VM", phase: phase, snapshots: VMSnapshotManifest(snapshots: [snapshot])
        ) {
            $0.memorySizeInGB = .gibibytes(16)
        }
        let layout = instance.bundleLayout
        try Data("live-disk".utf8).write(to: layout.diskImageURL)

        // The capture: taken while the VM had 8 GB and a second disk.
        var capturedConfiguration = instance.configuration
        capturedConfiguration.memorySizeInGB = .gibibytes(8)
        let extraID = UUID()
        capturedConfiguration.storageDisks = [
            StorageDisk(path: "Disk.asif", isInternal: true),
            StorageDisk(
                id: extraID, path: "AdditionalDisks/\(extraID.uuidString).asif", isInternal: true),
        ]
        let snapshotLayout = layout.snapshotLayout(id: snapshot.id)
        try FileManager.default.createDirectory(
            at: snapshotLayout.additionalDisksDirectoryURL, withIntermediateDirectories: true)
        try Data("captured-disk".utf8).write(to: snapshotLayout.diskImageURL)
        try Data("captured-extra".utf8).write(to: snapshotLayout.additionalDiskURL(id: extraID))
        try Data("captured-state".utf8).write(to: snapshotLayout.saveFileURL)
        try VMConfiguration.makeJSONEncoder().encode(capturedConfiguration)
            .write(to: snapshotLayout.configURL)

        return RevertFixture(instance: instance, snapshot: snapshot, library: library)
    }

    @Test("A revert to a state captured with the installer disk gives the VM its own copy from the snapshot's")
    func revertGivesTheVMItsOwnCopy() async throws {
        let fixture = try makeRevertFixture()
        let layout = fixture.instance.bundleLayout
        let item = RemovableMediaItem(path: "/app/agent.iso", readOnly: true)
        let snapshotCopy = layout.snapshotLayout(id: fixture.snapshot.id).guestAgentDiskCopyURL(for: item)
        try FileManager.default.createDirectory(
            at: snapshotCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the snapshot's copy".utf8).write(to: snapshotCopy)

        try await revert(fixture)

        let copy = layout.guestAgentDiskCopyURL(for: item)
        #expect(try Data(contentsOf: copy) == Data("the snapshot's copy".utf8))
        // The snapshot keeps its own, for the next revert.
        #expect(FileManager.default.fileExists(atPath: snapshotCopy.path(percentEncoded: false)))
    }

    /// Reverts `fixture`'s VM to the fixture's snapshot inside the revert
    /// bring-up the VM admits, handing the written configuration to
    /// `commitConfiguration`, or to the fixture's library.
    private func revert(
        _ fixture: RevertFixture,
        commitConfiguration: (@MainActor (borrowing VMEditPermit, VMSnapshotRestorePlan) throws -> Void)? = nil
    ) async throws {
        let commit =
            commitConfiguration ?? { permit, plan in
                try fixture.library.commitRevertedConfiguration(plan, permit)
            }
        try await fixture.instance.activity.launchRevert(to: fixture.snapshot, resumesAfter: false) {
            context in
            try await service.revertToSnapshot(
                fixture.instance, context, commitConfiguration: commit)
        }.value()
    }

    /// Captures `snapshot` from `instance` inside the capture operation the VM
    /// admits, in the mode its state offers.
    private func capture(
        _ instance: VMInstance, _ snapshot: VMSnapshotCaptureRequest
    ) async throws -> VMSnapshot {
        let mode = try #require(instance.snapshotCaptureMode)
        return try await instance.activity.launchedCapture(mode) { context in
            try await service.takeSnapshot(instance, context, snapshot: snapshot)
        }
    }

    // MARK: - Device shape

    private nonisolated static let noSocketDevice = VMDeviceShape(virtioSocketDevice: false)

    @Test("An incomplete snapshot is refused before the live VM is torn down")
    func revertRefusesBeforeTearingTheVMDown() async throws {
        let fixture = try makeRevertFixture(phase: .running(sessionID: UUID()))
        // The snapshot loses the file its own configuration names, so the
        // pre-flight refuses.
        let snapshotLayout = fixture.instance.bundleLayout.snapshotLayout(id: fixture.snapshot.id)
        try FileManager.default.removeItem(at: snapshotLayout.diskImageURL)

        await #expect(throws: VMSnapshotError.self) {
            try await revert(fixture)
        }

        // Untouched: no `.restoring`, no resting status applied, and the VM's
        // own disk still holds what the live guest wrote.
        #expect(fixture.instance.status == .running)
        let liveDisk = try Data(contentsOf: fixture.instance.bundleLayout.diskImageURL)
        #expect(String(decoding: liveDisk, as: UTF8.self) == "live-disk")
    }

    /// The text of the file at `url`, `nil` when there is none.
    private func contents(of url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("A revert whose configuration commit fails leaves the disks and suspend slot untouched")
    func revertWhoseCommitFailsTouchesNoFile() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        let layout = fixture.instance.bundleLayout
        try Data("own-suspend-slot".utf8).write(to: layout.saveFileURL)
        struct CommitFailed: Error {}

        await #expect(throws: CommitFailed.self) {
            try await revert(fixture) { _, _ in throw CommitFailed() }
        }

        #expect(contents(of: layout.diskImageURL) == "live-disk")
        #expect(contents(of: layout.saveFileURL) == "own-suspend-slot")
        #expect(fixture.instance.configuration.memorySizeInGB == .gibibytes(16))
        #expect(!FileManager.default.fileExists(atPath: layout.restoreStagingURL.path(percentEncoded: false)))
        #expect(fixture.instance.phase == .suspended)
    }

    // MARK: - Suspended-state snapshots

    @Test("A suspended-state capture keeps the version that wrote the slot, not the capturing Kernova's")
    func suspendedCaptureKeepsTheSlotsWriter() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        let slot = fixture.instance.bundleLayout.saveFileURL
        try Data("bundle-suspend-slot".utf8).write(to: slot)
        try SavedStateVersion.record("0.9.0 (300)", at: slot)
        let snapshot = VMSnapshotCaptureRequest(name: "Suspended")

        _ = try await capture(fixture.instance, snapshot)

        #expect(fixture.instance.savedStateVersion(ofSnapshot: snapshot.id) == "0.9.0 (300)")
        #expect(fixture.instance.savedStateVersion == "0.9.0 (300)")
    }

    /// The capture is offered by ``VMInstance/snapshotCaptureMode``, which reads
    /// the slot rather than the phase, so the capture itself has to take every
    /// VM that offer admits — otherwise Take Snapshot is offered, confirmed and
    /// then refused for the state it was offered in.
    @Test(
        "A suspended-state capture takes any VM resting on a slot, whatever phase it rests at",
        arguments: [VMLifecyclePhase.stopped, .failed(message: "Restore failed.")])
    func suspendedCaptureFollowsTheSlotNotThePhase(phase: VMLifecyclePhase) async throws {
        let fixture = try makeRevertFixture(phase: phase)
        try Data("bundle-suspend-slot".utf8).write(to: fixture.instance.bundleLayout.saveFileURL)
        #expect(fixture.instance.snapshotCaptureMode == .suspended)
        let snapshot = VMSnapshotCaptureRequest(name: "Suspended")

        _ = try await capture(fixture.instance, snapshot)

        let snapshotLayout = fixture.instance.bundleLayout.snapshotLayout(id: snapshot.id)
        let capturedSlot = try Data(contentsOf: snapshotLayout.saveFileURL)
        #expect(String(decoding: capturedSlot, as: UTF8.self) == "bundle-suspend-slot")
        // The slot is still there, so the VM keeps offering the session it
        // names — the capture consumed nothing and moved nothing.
        #expect(fixture.instance.hasSaveFile)
        #expect(fixture.instance.phase == .suspended)
    }

    // MARK: - Start

    /// Brings `instance` up by `kind` inside the bring-up the VM admits,
    /// running the real start body.
    private func start(
        _ instance: VMInstance, _ kind: VMGuestStartKind = .starting(recovery: false),
        on service: VirtualizationService? = nil
    ) async throws {
        let service = service ?? self.service
        try await instance.activity.launchStartGuest(kind) { context in
            switch try await service.start(instance, context, provisioning: nil) {
            case .rest(let rest, _): .rest(rest, ())
            case .failed(let rest, let error): .failed(rest, error)
            }
        }.value()
    }

    // MARK: - Duplicate Identity at Bring-Up

    /// Two VMs on one MAC address and network, in one wired library, with the
    /// first live — the refusal the bring-up test below expects.
    private func makeLiveMACPair(
        restingAt phase: VMLifecyclePhase
    ) -> (library: VMLibrary, resting: VMInstance, live: VMInstance) {
        let library = makeWiredLibrary()
        let resting = library.registerFixture(name: "Resting", phase: phase) {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:40"
        }
        let live = library.registerFixture(name: "Live", phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:40"
        }
        return (library, resting, live)
    }

    /// The identity conflict a refusal carries, or `nil` for any other error.
    private func identityConflict(in error: (any Error)?) -> VMIdentityConflict? {
        guard case .identityConflict(let conflict)? = (error as? VMAdmissionRefusal)?.refusal
        else { return nil }
        return conflict
    }

    @Test("A restore onto a live identity is refused, keeping the saved state")
    func coldResumeRefusesALiveIdentityKeepingTheSavedState() async throws {
        let (library, resting, live) = makeLiveMACPair(restingAt: .suspended)
        try VMInstanceFixture.writeSaveFile(for: resting)

        let refusal = await #expect(throws: VMAdmissionRefusal.self) {
            try await start(resting, .restoringSavedState)
        }

        #expect(identityConflict(in: refusal)?.other === live)
        #expect(resting.phase == .suspended)
        #expect(resting.hasSaveFile)
        #expect(resting.sessionContext == nil)
        withExtendedLifetime(library) {}
    }

    // MARK: - Transient Start Error Classification

    @Test("The classifier's framework constants are Virtualization's own")
    func frameworkConstantsAreVirtualizations() {
        typealias Code = VirtualizationFailure.Framework.Code
        #expect(VirtualizationFailure.Framework.errorDomain == VZError.errorDomain)
        #expect(
            Code.invalidVirtualMachineConfiguration.rawValue
                == VZError.Code.invalidVirtualMachineConfiguration.rawValue)
        #expect(Code.virtualMachineLimitExceeded.rawValue == VZError.Code.virtualMachineLimitExceeded.rawValue)
        #expect(Code.operationCancelled.rawValue == VZError.Code.operationCancelled.rawValue)
        #expect(vzInstallationFailedCode == VZError.Code.installationFailed.rawValue)
    }

    @Test("The underlying chain description names every link, bounded")
    func underlyingChainDescriptionNamesEveryLink() {
        #expect(
            VirtualizationFailure.underlyingChainDescription(makeInstallVMLimitExceededError())
                == "\(VZError.errorDomain) \(VZError.Code.virtualMachineLimitExceeded.rawValue)")
        #expect(
            VirtualizationFailure.underlyingChainDescription(makeVMLimitExceededError()) == "none")
        let deep = makeVZErrorChain(depth: 6, around: makeVMLimitExceededError())
        #expect(
            VirtualizationFailure.underlyingChainDescription(deep)
                .components(separatedBy: " → ").count == 4)
    }

    // MARK: - File-Lock Contention Classification

    /// Mirrors the error VZ throws when a dying VM still holds the advisory
    /// lock on `AuxiliaryStorage` (captured from a live repro on macOS 26):
    /// `.invalidVirtualMachineConfiguration` with POSIX `EAGAIN` underneath.
    private func makeFileLockContentionError() -> NSError {
        NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.invalidVirtualMachineConfiguration.rawValue,
            userInfo: [
                NSLocalizedFailureReasonErrorKey: "Failed to lock auxiliary storage.",
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN)),
            ])
    }

    @Test("invalid configuration with underlying EAGAIN is lock contention")
    func eagainUnderInvalidConfigurationIsLockContention() {
        #expect(VirtualizationFailure.isFileLockContention(makeFileLockContentionError()))
    }

    @Test("a non-contention attach failure stays permanent")
    func wrappedNonContentionAttachFailureIsPermanent() {
        // The sandbox-denied-open case: real, not transient, and must keep
        // landing the VM in .error rather than being retried as contention.
        let wrapped = ConfigurationBuilderError.storageDiskAttachFailed(
            id: UUID(), path: "/tmp/Disk.asif", label: "Main Disk",
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))
        #expect(!VirtualizationFailure.isFileLockContention(wrapped))
        #expect(!VirtualizationFailure.isTransientStartError(wrapped))
    }

    @Test("file-lock retry delays escalate then exhaust")
    func fileLockRetryDelaysEscalateThenExhaust() {
        #expect(VirtualizationService.fileLockRetryDelay(forAttempt: 0) == .milliseconds(250))
        #expect(VirtualizationService.fileLockRetryDelay(forAttempt: 1) == .milliseconds(500))
        #expect(VirtualizationService.fileLockRetryDelay(forAttempt: 2) == .seconds(1))
        #expect(VirtualizationService.fileLockRetryDelay(forAttempt: 3) == .seconds(2))
        #expect(VirtualizationService.fileLockRetryDelay(forAttempt: 4) == nil)
    }

    // MARK: - Resting Phases

    @Test("A VM with a suspend slot rests suspended, and one without it rests stopped")
    func restingPhaseForSuspendSlotReadsTheBundle() throws {
        let holding = VMInstanceFixture.make(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: holding)

        holding.activity.placeForTesting(holding.restingPhase(withoutSlot: .stopped))

        #expect(holding.status == .suspended)
        #expect(holding.isSuspended)
        #expect(holding.errorMessage == nil)
        #expect(holding.hasSaveFile)

        let emptied = VMInstanceFixture.make(phase: .suspended)
        emptied.activity.placeForTesting(emptied.restingPhase(withoutSlot: .stopped))
        #expect(emptied.status == .stopped)
        #expect(emptied.errorMessage == nil)
    }

    /// Fails a bring-up of `kind` on `instance` with `error`, answering where
    /// the VM rests.
    private func restAfterFailedBringUp(
        _ kind: VMBringUpKind, on instance: VMInstance, with error: any Error
    ) async -> VMLifecyclePhase {
        _ = try? await instance.activity.launchAnyBringUp(kind) {
            (_: borrowing VMBringUpContext) -> VMOperationEnding<Void> in
            throw error
        }.value()
        return instance.phase
    }

    @Test("Every bring-up failure over a kept suspend slot rests suspended, whatever it failed on")
    func restingPhaseAfterLifecycleFailureFollowsTheSaveFile() async throws {
        // One builder failure, one raw VZ error, one transient error, and the
        // restore failure itself: the slot decides all four.
        let failures: [(label: String, error: any Error)] = [
            (
                "configuration build",
                ConfigurationBuilderError.storageDiskAttachFailed(
                    id: UUID(), path: "/missing.img", label: "Scratch",
                    underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
            ),
            (
                "raw VZ validation",
                NSError(
                    domain: VZError.errorDomain,
                    code: VZError.Code.invalidVirtualMachineConfiguration.rawValue)
            ),
            (
                "lock contention, classed transient",
                NSError(
                    domain: VZError.errorDomain,
                    code: VZError.Code.invalidVirtualMachineConfiguration.rawValue,
                    userInfo: [
                        NSUnderlyingErrorKey: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
                    ])
            ),
            ("restore", VirtualizationError.restoreFailed(underlying: NSError(domain: "t", code: 1))),
        ]
        for failure in failures {
            let instance = VMInstanceFixture.make(phase: .suspended)
            try VMInstanceFixture.writeSaveFile(for: instance)
            #expect(
                await restAfterFailedBringUp(.guestStart(.restoringSavedState), on: instance, with: failure.error)
                    == .suspended, "\(failure.label)")
        }
    }

    @Test("Without a suspend slot, a start failure rests where it classifies")
    func restingPhaseAfterLifecycleFailureWithoutASlot() async {
        // A permanent start failure rests at `.failed` carrying the message.
        let permanent = await restAfterFailedBringUp(
            .guestStart(.starting(recovery: false)), on: VMInstanceFixture.make(phase: .stopped),
            with: VirtualizationError.noVirtualMachine)
        #expect(permanent.status == .error)
        #expect(permanent.errorMessage != nil)

        // A transient start failure rests stopped with no message.
        #expect(
            await restAfterFailedBringUp(
                .guestStart(.starting(recovery: false)), on: VMInstanceFixture.make(phase: .stopped),
                with: NSError(
                    domain: VZError.errorDomain, code: VZError.Code.operationCancelled.rawValue))
                == .stopped)
    }

    // MARK: - Failure copy

    @Test("A failed restore states what is known and promises no retry")
    func restoreFailedCopyStatesOnlyWhatIsKnown() {
        let message = VirtualizationError.restoreFailed(
            underlying: NSError(
                domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The disk is missing."])
        ).localizedDescription

        #expect(message.contains("The disk is missing."))
        #expect(message.contains("The saved state was kept."))
        // After the device set has diverged from the one the state was written
        // with, no retry can succeed — and which commands the VM offers is its
        // own state's answer.
        #expect(!message.lowercased().contains("try again"))
        #expect(!message.contains("Resume"))
        #expect(!message.contains("locked"))
    }

    @Test("A restore that failed while the Mac was locked says an unlock is needed")
    func restoreFailedWhileLockedNamesTheUnlock() {
        let message = VirtualizationError.restoreFailed(
            underlying: NSError(
                domain: VZError.errorDomain, code: VZError.Code.restore.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "permission denied"]),
            hostLocked: true
        ).localizedDescription

        #expect(message.contains("permission denied"))
        #expect(message.contains("can be restored only while it is unlocked"))
        #expect(message.hasSuffix("The saved state was kept."))
    }

    @Test("A revert whose resume failed names the Resume the VM is left offering")
    func revertResumeFailedNamesTheOfferedVerb() async throws {
        let message = VirtualizationError.revertResumeFailed(
            underlying: NSError(
                domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The share is missing."])
        ).localizedDescription
        #expect(message.contains("choose Resume to try again"))

        // True because the failure rests the VM on the slot the revert wrote:
        // the snapshot's saved state is still there, so Resume is what it
        // offers.
        let snapshot = VMSnapshot(name: "Warm", macAddress: nil)
        let instance = VMInstanceFixture.make(
            phase: .suspended, snapshots: VMSnapshotManifest(snapshots: [snapshot]))
        try VMInstanceFixture.writeSaveFile(for: instance)
        #expect(
            await restAfterFailedBringUp(
                .reverting(snapshotID: snapshot.id, resumesAfter: true), on: instance,
                with: VirtualizationError.revertResumeFailed(
                    underlying: ConfigurationBuilderError.sharedDirectoryNotFound(
                        id: UUID(), path: "/gone", label: "gone")))
                == .suspended)
    }

    @Test("A boot whose heal cannot be saved builds from the healed references")
    func bootWhoseHealFailsBuildsFromTheHealedReferences() async throws {
        let directory = scratch.url.appendingPathComponent("bootHeal", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let picked = directory.appendingPathComponent("Picked.kernel")
        try Data("kernel".utf8).write(to: picked)
        let bookmark = try #require(SecurityScopedBookmark.make(for: picked))
        // Moved since the pick, so only the bookmark still finds it.
        try FileManager.default.moveItem(
            at: picked, to: directory.appendingPathComponent("Moved.kernel"))
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = library.registerFixture(phase: .stopped) {
            $0.bootMode = .linuxKernel
            $0.kernelPath = picked.path(percentEncoded: false)
            $0.kernelBookmark = bookmark
        }
        defer { withExtendedLifetime(library) {} }
        storage.setSaveConfigurationError(NSError(domain: "test", code: 1))

        var thrown: (any Error)?
        do {
            try await start(instance)
        } catch {
            thrown = error
        }

        // The build got past the kernel, which only the healed path names, and
        // failed on the bundle's missing main disk instead.
        guard case ConfigurationBuilderError.storageDiskNotFound = try #require(thrown) else {
            Issue.record("expected the build to reach the main disk, got \(String(describing: thrown))")
            return
        }
        #expect(instance.configuration.kernelPath == picked.path(percentEncoded: false))
        #expect(storage.bundles[instance.bundleURL]?.kernelPath == picked.path(percentEncoded: false))
    }

    @Test("A cold boot whose device shape cannot be recorded builds nothing")
    func coldBootRefusesAnUnrecordedShape() async throws {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = library.registerFixture(phase: .stopped) {
            $0.deviceShape = Self.noSocketDevice
        }
        defer { withExtendedLifetime(library) {} }
        storage.setSaveConfigurationError(NSError(domain: "test", code: 1))

        await #expect(throws: VMLibrary.SettingsWriteFailure.self) {
            try await start(instance)
        }
        #expect(instance.configuration.deviceShape == Self.noSocketDevice)
        #expect(instance.session == nil)
    }
}
