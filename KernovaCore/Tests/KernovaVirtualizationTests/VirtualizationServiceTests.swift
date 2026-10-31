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

    // MARK: - A bring-up that fails before its session is live

    @Test("A bring-up that fails with a session context open rests the VM and releases the context")
    func failedBringUpRestsTheVMAndReleasesItsContext() async {
        let instance = VMInstanceFixture.make(phase: .stopped)
        struct GuestStopped: LocalizedError {
            var errorDescription: String? { "The guest stopped." }
        }

        await #expect(throws: GuestStopped.self) {
            try await instance.activity.launchAnyBringUp(.guestStart(.starting(recovery: false))) {
                (context: borrowing VMBringUpContext) -> VMOperationEnding<Void> in
                instance.beginSessionContextForTesting()
                context.bindSessionForTesting(UUID())
                throw GuestStopped()
            }.value()
        }

        #expect(instance.phase == .failed(message: "The guest stopped."))
        #expect(instance.sessionContext == nil)
    }

    // MARK: - Suspend

    /// Suspends `instance` over `session` inside the save operation the VM
    /// admits.
    private func suspend(_ instance: VMInstance, over session: MockSnapshotSession) async throws {
        try await instance.activity.perform(.saving) { context in
            try await VirtualizationService.save(instance, context, consent: .all, session: session)
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

    @Test("A suspend whose USB question is still open leaves the guest running and the slot as it was")
    func suspendAskingLeavesTheGuestRunning() async throws {
        let sessionID = UUID()
        let data = RemovableMediaItem(path: "/Volumes/Data.img", readOnly: false, label: "Data")
        let instance = VMInstanceFixture.make(phase: .running(sessionID: sessionID)) {
            $0.removableMedia = [data]
        }
        instance.beginSessionContextForTesting()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: data.id, path: data.path, readOnly: false), for: sessionID)
        let session = MockSnapshotSession(guestState: .running)
        await session.setUSBDevices([data.id])
        // A slot already there, which a refusal must not touch.
        try VMInstanceFixture.writeSaveFile(for: instance)

        let error = await #expect(throws: CommandError.self) {
            try await instance.activity.perform(.saving) { context in
                try await VirtualizationService.save(
                    instance, context, consent: Consent([.unplugUSBDisks]), session: session)
            }
        }

        #expect(error?.confirmationPrompt?.kind == .unplugUSBDisksAtRisk)
        #expect(instance.phase == .running(sessionID: sessionID))
        #expect(instance.hasSaveFile)
        #expect(await session.calls.isEmpty)
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

    // MARK: - A bundle that moves under an operation

    /// A VM in `phase` holding a suspend slot, and a second bundle for the same
    /// VM — what the library re-binds it to once its bundle moves — holding
    /// one too, standing in for the slot the move carried along.
    private func vmWithMovedBundle(
        phase: VMLifecyclePhase
    ) throws -> (instance: VMInstance, moved: VMBundle) {
        let files = InMemoryVMBundleFiles()
        let factory = VMBundle.Factory(machineFiles: MockVMBundleMachineFiles(files: files))
        let instance = VMInstanceFixture.make(phase: phase, files: files, bundleFactory: factory)
        let movedURL = scratch.url
            .appendingPathComponent("Moved.kernova", isDirectory: true)
        files.seed(instance.configuration, at: movedURL)
        let moved = factory.make(VMInstanceFixture.read(movedURL, from: files))
        for bundleURL in [instance.bundleURL, movedURL] {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try Data("suspend slot".utf8).write(to: VMBundleLayout(bundleURL: bundleURL).saveFileURL)
        }
        return (instance, moved)
    }

    @Test("A save after the VM's bundle moved writes and drops the slot where the bundle now is")
    func saveAfterAMoveFollowsTheBundle() async throws {
        let (instance, moved) = try vmWithMovedBundle(phase: .running(sessionID: UUID()))
        let original = instance.bundleLayout
        let movedLayout = VMBundleLayout(bundleURL: moved.url)
        let session = MockSnapshotSession(guestState: .running)
        await session.setSaveError(NSError(domain: "test", code: 1))

        await #expect(throws: (any Error).self) {
            try await instance.activity.perform(.saving) { context in
                instance.rebind(to: moved)
                return try await VirtualizationService.save(instance, context, consent: .all, session: session)
            }
        }

        #expect(await session.savedStateURLs == [movedLayout.saveFileURL])
        #expect(!movedLayout.hasSaveFile)
        #expect(original.hasSaveFile)
    }

    @Test("A save whose bundle moves mid-write drops the partial slot where the bundle now is")
    func saveWhoseBundleMovesMidWriteFollowsTheBundle() async throws {
        let (instance, moved) = try vmWithMovedBundle(phase: .running(sessionID: UUID()))
        let original = instance.bundleLayout
        let movedLayout = VMBundleLayout(bundleURL: moved.url)
        let session = MockSnapshotSession(guestState: .running)
        // The bundle moves once VZ holds the slot's URL, and the guest then
        // goes away, so the partial slot is dropped after the move.
        await session.setAfterSave {
            await MainActor.run {
                instance.rebind(to: moved)
                instance.handleSessionEvent(.guestDidStop)
            }
        }

        try await instance.activity.perform(.saving) { context in
            try await VirtualizationService.save(instance, context, consent: .all, session: session)
        }

        #expect(await session.savedStateURLs == [original.saveFileURL])
        #expect(!movedLayout.hasSaveFile)
        #expect(original.hasSaveFile)
    }

    @Test("A restore whose bundle moves mid-restore drops the slot where the bundle now is")
    func restoreWhoseBundleMovesMidRestoreFollowsTheBundle() async throws {
        let (instance, moved) = try vmWithMovedBundle(phase: .suspended)
        let original = instance.bundleLayout
        let movedLayout = VMBundleLayout(bundleURL: moved.url)
        let session = MockSnapshotSession(guestState: .paused)
        await session.setAfterRestore {
            await MainActor.run { instance.rebind(to: moved) }
        }

        try await instance.activity.launchStartGuest(.restoringSavedState) { context in
            try await VirtualizationService.restoreSavedState(
                instance, context.bringUp.operation, session: session,
                isProtectedDataAvailable: { true })
            context.bringUp.bindSessionForTesting(UUID())
            return .rest(.live(.running), ())
        }.value()

        #expect(await session.restoredStateURLs == [original.saveFileURL])
        #expect(!movedLayout.hasSaveFile)
        #expect(!holdsSpentSlot(movedLayout))
        #expect(original.hasSaveFile)
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

    @Test("A restore marks its session unsettled and spends the slot before the guest resumes")
    func restoreMarksBeforeTheGuestResumes() async throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let session = MockSnapshotSession(guestState: .paused)
        let record = MarkerRecord()
        await session.setBeforeResume {
            await MainActor.run {
                record.atResume = instance.hostState.hasUnsettledSession
                #expect(!instance.hasSaveFile)
            }
        }

        try await restore(instance, over: session)

        #expect(record.atResume == true)
        #expect(instance.hostState.hasUnsettledSession)
        #expect(!instance.hasSaveFile)
        #expect(!holdsSpentSlot(instance.bundleLayout))
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

    @Test("A cold boot starts without the installer disk the last session had")
    func coldBootStartsWithoutTheInstallerDisk() async throws {
        let (service, products, cache) = try linuxAgentProducts()
        let library = makeWiredLibrary(bundleProducts: products)
        defer { withExtendedLifetime(library) {} }
        let item = RemovableMediaItem(path: cache.url.path(percentEncoded: false), readOnly: true)
        let instance = library.registerFixture(phase: .stopped) { $0.removableMedia = [item] }
        try FileManager.default.createDirectory(at: instance.bundleURL, withIntermediateDirectories: true)

        // The bundle holds no real disk image, so the boot fails at the
        // configuration build, after the configuration is settled.
        await #expect(throws: ConfigurationBuilderError.self) { try await start(instance, on: service) }

        #expect(instance.configuration.removableMedia == nil)
    }

    @Test("A restore keeps the installer entry for the reconcile to plug back in, and builds no copy of it")
    func restoreKeepsTheInstallerEntry() async throws {
        let (service, products, cache) = try linuxAgentProducts()
        let path = cache.url.path(percentEncoded: false)
        let item = RemovableMediaItem(path: path, readOnly: true)
        let instance = VMInstanceFixture.make(phase: .suspended, bundleProducts: products) {
            $0.removableMedia = [item]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)

        // The build stops at the bundle's missing main disk.
        await #expect(throws: ConfigurationBuilderError.self) {
            try await start(instance, .restoringSavedState, on: service)
        }

        #expect(instance.configuration.removableMedia?.map(\.path) == [path])
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
                instance, context, snapshot: snapshot, consent: .all, session: session)
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

    @Test("A warm snapshot unplugs the installer disk, and keeps its entry for the reconcile to plug back in")
    func warmSnapshotUnplugsTheInstallerDisk() async throws {
        let store = MockVMBundleMachineFiles()
        let library = makeWiredLibrary(machineFiles: store)
        let sessionID = UUID()
        let path = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL).path(percentEncoded: false)
        let installer = RemovableMediaItem(path: path, readOnly: true)
        let instance = library.registerFixture(guestOS: .macOS, phase: .running(sessionID: sessionID)) {
            $0.removableMedia = [installer]
        }
        instance.beginSessionContextForTesting()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: installer.id, path: path, readOnly: true), for: sessionID)
        let session = MockSnapshotSession(guestState: .running)
        await session.setUSBDevices([installer.id])

        let captured = try await captureWarm(
            instance, snapshot: VMSnapshotCaptureRequest(name: "With the disk"), session: session)

        #expect(await session.detachedUSBDeviceIDs == [installer.id])
        #expect(store.capturedConfiguration(for: captured.id)?.removableMedia == [installer])
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
        /// What the snapshot recorded, which the revert has to install.
        let capturedConfiguration: VMConfiguration
        /// Holds the instance, as the library a revert hands the written
        /// configuration to.
        let library: VMLibrary
    }

    private func makeRevertFixture(
        phase: VMLifecyclePhase = .stopped, kind: VMSnapshotKind = .warm,
        macAddress: String? = nil, capturedMACAddress: String? = nil,
        deviceShape: VMDeviceShape = .current, capturedDeviceShape: VMDeviceShape? = nil,
        machineFiles: (any VMBundleMachineFileWorking)? = nil
    ) throws -> RevertFixture {
        let snapshot = VMSnapshot(name: "Before the update", kind: kind, macAddress: nil)
        let library = makeWiredLibrary(
            machineFiles: machineFiles
                ?? VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()))
        let instance = try library.registerOnDiskFixture(
            name: "Revert VM", phase: phase, snapshots: VMSnapshotManifest(snapshots: [snapshot])
        ) {
            $0.memorySizeInGB = .gibibytes(16)
            $0.macAddress = macAddress
            $0.deviceShape = deviceShape
        }
        let layout = instance.bundleLayout
        try Data("live-disk".utf8).write(to: layout.diskImageURL)

        // The capture: taken while the VM had 8 GB and a second disk.
        var capturedConfiguration = instance.configuration
        capturedConfiguration.memorySizeInGB = .gibibytes(8)
        capturedConfiguration.macAddress = capturedMACAddress ?? macAddress
        capturedConfiguration.deviceShape = capturedDeviceShape ?? deviceShape
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
        if kind == .warm {
            try Data("captured-state".utf8).write(to: snapshotLayout.saveFileURL)
        }
        try VMConfiguration.makeJSONEncoder().encode(capturedConfiguration)
            .write(to: snapshotLayout.configURL)

        return RevertFixture(
            instance: instance, snapshot: snapshot,
            capturedConfiguration: capturedConfiguration,
            library: library)
    }

    @Test("A revert to a state captured with the virtio installer disk gives the VM its own copy from the snapshot's")
    func revertGivesTheVMItsOwnCopy() async throws {
        let fixture = try makeRevertFixture()
        let layout = fixture.instance.bundleLayout
        let dmg = URL(filePath: "/app/agent.dmg")
        let snapshotCopy = layout.snapshotLayout(id: fixture.snapshot.id).guestAgentVirtioDiskURL(of: dmg)
        try FileManager.default.createDirectory(
            at: snapshotCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the snapshot's copy".utf8).write(to: snapshotCopy)

        try await revert(fixture)

        let copy = layout.guestAgentVirtioDiskURL(of: dmg)
        #expect(try Data(contentsOf: copy) == Data("the snapshot's copy".utf8))
        // The snapshot keeps its own, for the next revert.
        #expect(FileManager.default.fileExists(atPath: snapshotCopy.path(percentEncoded: false)))
    }

    /// Reverts `fixture`'s VM to `snapshot` — the fixture's own unless named —
    /// inside the revert bring-up the VM admits, handing the written
    /// configuration to `commitConfiguration`, or to the fixture's library.
    private func revert(
        _ fixture: RevertFixture, to snapshot: VMSnapshot? = nil,
        commitConfiguration: (@MainActor (borrowing VMEditPermit, VMSnapshotRestorePlan) throws -> Void)? = nil
    ) async throws {
        let target = snapshot ?? fixture.snapshot
        let commit =
            commitConfiguration ?? { permit, plan in
                try fixture.library.commitRevertedConfiguration(plan, permit)
            }
        try await fixture.instance.activity.launchRevert(to: target, resumesAfter: false) {
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
            try await service.takeSnapshot(instance, context, snapshot: snapshot, consent: .all)
        }
    }

    @Test("A revert installs the configuration the snapshot captured, keeping identity")
    func revertInstallsTheCapturedConfiguration() async throws {
        let fixture = try makeRevertFixture()
        let originalID = fixture.instance.configuration.id

        try await revert(fixture)

        #expect(fixture.instance.configuration.memorySizeInGB == .gibibytes(8))
        #expect(fixture.instance.configuration.id == originalID)
        #expect(fixture.instance.configuration.name == "Revert VM")
        // On disk too, so a later load reads the same settings the saved state
        // was written under.
        let written = try VMConfiguration.load(fromBundle: fixture.instance.bundleURL)
        #expect(written.memorySizeInGB == .gibibytes(8))
        #expect(written.name == "Revert VM")
    }

    @Test("A revert restores a disk the VM no longer configures")
    func revertRestoresADiskDroppedSinceTheCapture() async throws {
        let fixture = try makeRevertFixture()
        let layout = fixture.instance.bundleLayout
        let extraPath = fixture.capturedConfiguration.storageDisks?.last?.path ?? ""

        try await revert(fixture)

        let restoredExtra = layout.bundleURL.appendingPathComponent(extraPath)
        #expect(FileManager.default.fileExists(atPath: restoredExtra.path(percentEncoded: false)))
        let mainDisk = try Data(contentsOf: layout.diskImageURL)
        #expect(String(decoding: mainDisk, as: UTF8.self) == "captured-disk")
    }

    @Test("A revert commits the captured configuration before the VM leaves the revert")
    func revertHandsTheWrittenConfigurationOverBeforeResting() async throws {
        let fixture = try makeRevertFixture(
            macAddress: "aa:bb:cc:dd:ee:02", capturedMACAddress: "aa:bb:cc:dd:ee:01")
        var adopted: [VMSnapshotRestorePlan] = []

        try await revert(fixture) { permit, plan in
            // Anything that brings the VM back up reads its configuration after
            // this, so the commit lands while the VM has not left the revert yet.
            #expect(
                fixture.instance.phase.operation?.kind
                    == .bringUp(.reverting(snapshotID: fixture.snapshot.id, resumesAfter: false)))
            adopted.append(plan)
            try fixture.library.commitRevertedConfiguration(plan, permit)
            let onDisk = try? VMConfiguration.load(fromBundle: fixture.instance.bundleURL)
            #expect(onDisk?.macAddress == plan.configuration.macAddress)
            #expect(onDisk?.memorySizeInGB == plan.configuration.memorySizeInGB)
        }

        let plan = try #require(adopted.first)
        #expect(adopted.count == 1)
        // The saved state restores only under the address it was taken with.
        #expect(plan.configuration.macAddress == "aa:bb:cc:dd:ee:01")
        #expect(fixture.instance.configuration == plan.configuration)
    }

    @Test("A capture's entry carries the MAC address of the configuration it wrote")
    func captureAnswersTheSnapshotWithItsMACAddress() async throws {
        let fixture = try makeRevertFixture(macAddress: "aa:bb:cc:dd:ee:03")
        let snapshot = VMSnapshotCaptureRequest(name: "Before first boot")

        let captured = try await capture(fixture.instance, snapshot)

        #expect(captured.id == snapshot.id)
        #expect(captured.kind == .cold)
        #expect(captured.macAddress == "aa:bb:cc:dd:ee:03")
        let written = try VMConfiguration.load(
            fromBundle: fixture.instance.bundleLayout.snapshotLayout(id: snapshot.id).bundleURL)
        #expect(written.macAddress == captured.macAddress)
    }

    // MARK: - Device shape

    private nonisolated static let noSocketDevice = VMDeviceShape(virtioSocketDevice: false)

    @Test("A capture records the device shape the VM holds, and a revert restores the snapshot's")
    func snapshotCarriesItsDeviceShape() async throws {
        let fixture = try makeRevertFixture(
            deviceShape: .current, capturedDeviceShape: Self.noSocketDevice)
        let request = VMSnapshotCaptureRequest(name: "Under the current shape")

        _ = try await capture(fixture.instance, request)
        let written = try VMConfiguration.load(
            fromBundle: fixture.instance.bundleLayout.snapshotLayout(id: request.id).bundleURL)
        #expect(written.deviceShape == .current)

        try await revert(fixture)
        #expect(fixture.instance.configuration.deviceShape == Self.noSocketDevice)
        let onDisk = try VMConfiguration.load(fromBundle: fixture.instance.bundleURL)
        #expect(onDisk.deviceShape == Self.noSocketDevice)
    }

    @Test("A cold boot of a Linux VM whose config had no record builds and records the current shape")
    func coldBootRecordsTheCurrentShape() async throws {
        let fixture = try makeRevertFixture(deviceShape: .unrecorded(bootMode: .efi))
        let instance = fixture.instance

        try await instance.activity.launchAnyBringUp(.guestStart(.starting(recovery: false))) {
            context in
            let built = try instance.coldBootConfiguration(context)
            #expect(built.deviceShape == .current)
            return .rest(.atRest(.stopped), ())
        }.value()

        #expect(instance.configuration.deviceShape == .current)
        let onDisk = try VMConfiguration.load(fromBundle: instance.bundleURL)
        #expect(onDisk.deviceShape == .current)
    }

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

    @Test("A restore that fails rests the VM rather than leaving it mid-revert, and reaches the caller")
    func revertRestsTheVMWhenTheRestoreFails() async throws {
        // Past the pre-flight, failing at the restore's staging.
        let store = MockVMBundleMachineFiles()
        let fixture = try makeRevertFixture(
            phase: .running(sessionID: UUID()), machineFiles: store)
        store.setCapturedConfiguration(fixture.capturedConfiguration, for: fixture.snapshot.id)
        store.setStageError(VMSnapshotError.snapshotMissingFile("Disk.asif"))

        await #expect(throws: VMSnapshotError.self) {
            try await revert(fixture)
        }

        // The teardown already happened, so the VM rests where a failed restore
        // leaves it — stopped, the bundle holding no save file to resume from —
        // never left held by the revert.
        #expect(fixture.instance.status == .stopped)
        #expect(!fixture.instance.hasLiveVirtualMachine)
        #expect(fixture.instance.phase.operation == nil)
        // The captured configuration is committed only once the restore
        // staged, so the VM still holds its own 16 GB, not the snapshot's 8.
        #expect(fixture.instance.configuration.memorySizeInGB == .gibibytes(16))
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

    @Test("A revert commits the configuration before any file is swapped")
    func revertCommitsBeforeSwappingAnyFile() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        let layout = fixture.instance.bundleLayout
        try Data("own-suspend-slot".utf8).write(to: layout.saveFileURL)
        var diskAtCommit: String?
        var slotAtCommit: String?

        try await revert(fixture) { permit, plan in
            diskAtCommit = contents(of: layout.diskImageURL)
            slotAtCommit = contents(of: layout.saveFileURL)
            try fixture.library.commitRevertedConfiguration(plan, permit)
        }

        #expect(diskAtCommit == "live-disk")
        #expect(slotAtCommit == "own-suspend-slot")
        #expect(contents(of: layout.diskImageURL) == "captured-disk")
        #expect(contents(of: layout.saveFileURL) == "captured-state")
        #expect(fixture.instance.configuration.memorySizeInGB == .gibibytes(8))
    }

    /// Nothing rolls back: the swap is renames on one volume, and the disks it
    /// replaced are what the user chose to discard.
    @Test(
        "A revert whose install fails after the commit leaves the snapshot's configuration committed and no save file, and surfaces the error"
    )
    func revertWhoseInstallFailsLeavesTheCommittedConfigurationAndNoSaveFile() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        let layout = fixture.instance.bundleLayout
        try Data("own-suspend-slot".utf8).write(to: layout.saveFileURL)
        let stagedSlot = VMBundleLayout(bundleURL: layout.restoreStagingURL).saveFileURL

        await #expect(throws: (any Error).self) {
            try await revert(fixture) { permit, plan in
                try fixture.library.commitRevertedConfiguration(plan, permit)
                // The install's last swap, the saved state's, finds nothing to
                // move.
                try FileManager.default.removeItem(at: stagedSlot)
            }
        }

        #expect(fixture.instance.configuration.memorySizeInGB == .gibibytes(8))
        #expect(try VMConfiguration.load(fromBundle: fixture.instance.bundleURL).memorySizeInGB == .gibibytes(8))
        #expect(contents(of: layout.diskImageURL) == "captured-disk")
        #expect(!layout.hasSaveFile)
        #expect(fixture.instance.status == .stopped)
    }

    // MARK: - Cold snapshots

    @Test("A capture of a stopped VM writes the disks, no saved state, and rests stopped")
    func coldCaptureWritesDisksAndRestsStopped() async throws {
        let fixture = try makeRevertFixture()
        let snapshot = VMSnapshotCaptureRequest(name: "Before first boot")

        _ = try await capture(fixture.instance, snapshot)

        let snapshotLayout = fixture.instance.bundleLayout.snapshotLayout(id: snapshot.id)
        let captured = try Data(contentsOf: snapshotLayout.diskImageURL)
        #expect(String(decoding: captured, as: UTF8.self) == "live-disk")
        #expect(!snapshotLayout.hasSaveFile)
        #expect(fixture.instance.status == .stopped)
    }

    // MARK: - Suspended-state snapshots

    @Test(
        "A suspended-state capture clones the suspend slot and the disks, leaves the bundle's slot in place, and rests suspended"
    )
    func suspendedCaptureClonesTheSlotAndRestsSuspended() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        #expect(fixture.instance.isSuspended)
        try Data("bundle-suspend-slot".utf8).write(to: fixture.instance.bundleLayout.saveFileURL)
        let snapshot = VMSnapshotCaptureRequest(name: "Suspended")

        let captured = try await capture(fixture.instance, snapshot)

        #expect(captured.kind == .warm)
        let snapshotLayout = fixture.instance.bundleLayout.snapshotLayout(id: snapshot.id)
        let capturedSlot = try Data(contentsOf: snapshotLayout.saveFileURL)
        #expect(String(decoding: capturedSlot, as: UTF8.self) == "bundle-suspend-slot")
        let capturedDisk = try Data(contentsOf: snapshotLayout.diskImageURL)
        #expect(String(decoding: capturedDisk, as: UTF8.self) == "live-disk")
        // The bundle's own slot is untouched — a suspended capture consumes nothing.
        let bundleSlot = try Data(contentsOf: fixture.instance.bundleLayout.saveFileURL)
        #expect(String(decoding: bundleSlot, as: UTF8.self) == "bundle-suspend-slot")
        #expect(fixture.instance.phase == .suspended)
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

    @Test("A suspended VM with no save file offers no capture and is refused one")
    func suspendedCaptureNeedsASaveFile() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        #expect(fixture.instance.isSuspended)
        #expect(!fixture.instance.hasSaveFile)
        #expect(fixture.instance.snapshotCaptureMode == nil)

        await #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) {
            try await fixture.instance.activity.launchedCapture(.suspended) { context in
                try await service.takeSnapshot(
                    fixture.instance, context,
                    snapshot: VMSnapshotCaptureRequest(name: "No slot"), consent: .all)
            }
        }
        // The admission re-read the bundle and found no slot to rest on.
        #expect(fixture.instance.phase == .stopped)
    }

    @Test("Reverting to a suspended-state capture restores the cloned suspend slot and disks")
    func revertRoundTripsASuspendedCapture() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        #expect(fixture.instance.isSuspended)
        try Data("own-suspend-slot".utf8).write(to: fixture.instance.bundleLayout.saveFileURL)
        let checkpoint = try await capture(
            fixture.instance, VMSnapshotCaptureRequest(name: "Suspended checkpoint"))
        try fixture.instance.editSnapshotManifest { $0.insert(checkpoint) }
        #expect(fixture.instance.phase == .suspended)

        try await revert(fixture, to: checkpoint)

        #expect(fixture.instance.phase == .suspended)
        let restoredSlot = try Data(contentsOf: fixture.instance.bundleLayout.saveFileURL)
        #expect(String(decoding: restoredSlot, as: UTF8.self) == "own-suspend-slot")
        let restoredDisk = try Data(contentsOf: fixture.instance.bundleLayout.diskImageURL)
        #expect(String(decoding: restoredDisk, as: UTF8.self) == "live-disk")
    }

    @Test("Reverting a live VM to a snapshot taken while stopped lands it stopped, with no resume")
    func coldRevertOfALiveVMLandsStopped() async throws {
        let fixture = try makeRevertFixture(phase: .running(sessionID: UUID()), kind: .cold)

        try await revert(fixture)

        #expect(fixture.instance.status == .stopped)
        #expect(!fixture.instance.bundleLayout.hasSaveFile)
        let restored = try Data(contentsOf: fixture.instance.bundleLayout.diskImageURL)
        #expect(String(decoding: restored, as: UTF8.self) == "captured-disk")
    }

    @Test("Reverting a suspended VM to a snapshot taken while stopped clears its suspend slot")
    func coldRevertClearsTheSuspendSlot() async throws {
        let fixture = try makeRevertFixture(phase: .suspended, kind: .cold)
        try Data("stale-suspend".utf8).write(to: fixture.instance.bundleLayout.saveFileURL)

        try await revert(fixture)

        #expect(fixture.instance.status == .stopped)
        #expect(!fixture.instance.bundleLayout.hasSaveFile)
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

    /// A bring-up that gives up before the restore leaves the slot for the
    /// next one.
    @Test("A restore of a VM holding a saved state keeps the slot when it fails")
    func startOfASuspendedVMRestoresAndKeepsTheSlot() async throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)

        // The bundle holds no real disk image, so the attempt fails at the
        // configuration build — past admission, and before the restore.
        await #expect(throws: (any Error).self) {
            try await start(instance, .restoringSavedState)
        }

        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
        #expect(instance.errorMessage == nil)
    }

    // MARK: - Duplicate Identity at Bring-Up

    /// Two VMs on one MAC address and network, in one wired library, with the
    /// first live — the refusal both bring-up tests below expect.
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

    @Test("A start onto a live identity is refused before the VM leaves rest")
    func startRefusesALiveIdentityBeforeLeavingRest() async throws {
        let (library, resting, live) = makeLiveMACPair(restingAt: .stopped)

        let refusal = await #expect(throws: VMAdmissionRefusal.self) {
            try await start(resting)
        }

        let conflict = identityConflict(in: refusal)
        #expect(conflict?.other === live)
        #expect(conflict?.reason == .macAddress)
        #expect(resting.phase == .stopped)
        #expect(resting.sessionContext == nil)
        withExtendedLifetime(library) {}
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

    @Test("VM limit exceeded error is transient")
    func vmLimitExceededIsTransient() {
        let error = makeVMLimitExceededError()
        #expect(VirtualizationFailure.isVirtualMachineLimitExceeded(error))
        #expect(VirtualizationFailure.isTransientStartError(error))
    }

    @Test("VM limit exceeded is found anywhere within the bounded chain")
    func deeplyNestedVMLimitExceededIsFound() {
        for depth in 2...4 {
            let error = makeVZErrorChain(depth: depth, around: makeVMLimitExceededError())
            #expect(VirtualizationFailure.isVirtualMachineLimitExceeded(error))
            #expect(VirtualizationFailure.isTransientStartError(error))
        }
    }

    @Test("VM limit exceeded past the chain bound is not recognized")
    func vmLimitExceededBeyondBoundIsPermanent() {
        let error = makeVZErrorChain(depth: 5, around: makeVMLimitExceededError())
        #expect(!VirtualizationFailure.isVirtualMachineLimitExceeded(error))
        #expect(!VirtualizationFailure.isTransientStartError(error))
    }

    @Test("An installation failure carrying no underlying error is permanent")
    func installationFailedAloneIsPermanent() {
        let error = NSError(
            domain: VZError.errorDomain, code: VZError.Code.installationFailed.rawValue)
        #expect(!VirtualizationFailure.isVirtualMachineLimitExceeded(error))
        #expect(!VirtualizationFailure.isTransientStartError(error))
    }

    @Test("A builder error wrapping the VM limit stays permanent")
    func builderErrorWrappingLimitIsPermanent() {
        let wrapped = ConfigurationBuilderError.storageDiskAttachFailed(
            id: UUID(), path: "/tmp/Disk.asif", label: "Main Disk",
            underlying: makeVMLimitExceededError())
        #expect(!VirtualizationFailure.isTransientStartError(wrapped))
    }

    @Test("A nested operation cancelled is not transient")
    func nestedOperationCancelledIsPermanent() {
        let error = makeVZErrorChain(
            depth: 1,
            around: NSError(
                domain: VZError.errorDomain, code: VZError.Code.operationCancelled.rawValue))
        #expect(!VirtualizationFailure.isTransientStartError(error))
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

    @Test("operation cancelled error is transient")
    func operationCancelledIsTransient() {
        let error = NSError(domain: VZError.errorDomain, code: VZError.Code.operationCancelled.rawValue)
        #expect(VirtualizationFailure.isTransientStartError(error))
    }

    @Test("configuration builder error is permanent")
    func configBuilderErrorIsPermanent() {
        let error = ConfigurationBuilderError.missingKernelPath
        #expect(!VirtualizationFailure.isTransientStartError(error))
    }

    @Test("unknown domain error is permanent")
    func unknownDomainIsPermanent() {
        let error = NSError(domain: "SomeOtherDomain", code: 42)
        #expect(!VirtualizationFailure.isTransientStartError(error))
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

    @Test("lock contention wrapped in a disk attach failure is still lock contention")
    func wrappedLockContentionIsLockContention() {
        // The lock is taken on the disk image, so contention surfaces from the
        // attach — which the builder wraps to carry the item's identity. If the
        // classifier stopped unwrapping, the bounded retry would never fire and
        // a post-install auto-boot would fail on its first attempt.
        let wrapped = ConfigurationBuilderError.storageDiskAttachFailed(
            id: UUID(), path: "/tmp/Disk.asif", label: "Main Disk",
            underlying: makeFileLockContentionError())
        #expect(VirtualizationFailure.isFileLockContention(wrapped))
        #expect(VirtualizationFailure.isTransientStartError(wrapped))
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

    @Test("invalid configuration without underlying error is not lock contention")
    func invalidConfigurationAloneIsNotLockContention() {
        let error = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.invalidVirtualMachineConfiguration.rawValue)
        #expect(!VirtualizationFailure.isFileLockContention(error))
    }

    @Test("invalid configuration with non-EAGAIN underlying error is not lock contention")
    func nonEAGAINUnderlyingIsNotLockContention() {
        let error = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.invalidVirtualMachineConfiguration.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            ])
        #expect(!VirtualizationFailure.isFileLockContention(error))
        #expect(!VirtualizationFailure.isTransientStartError(error))
    }

    @Test("EAGAIN under a different VZ code is not lock contention")
    func eagainUnderOtherVZCodeIsNotLockContention() {
        let error = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.internalError.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
            ])
        #expect(!VirtualizationFailure.isFileLockContention(error))
    }

    @Test("top-level POSIX EAGAIN is not lock contention")
    func topLevelEAGAINIsNotLockContention() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
        #expect(!VirtualizationFailure.isFileLockContention(error))
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

    @Test("classifiers see through the restoreFailed wrapper")
    func classifiersSeeThroughRestoreFailedWrapper() {
        let limit = NSError(
            domain: VZError.errorDomain, code: VZError.Code.virtualMachineLimitExceeded.rawValue)
        #expect(
            VirtualizationFailure.isVirtualMachineLimitExceeded(
                VirtualizationError.restoreFailed(underlying: limit)))

        let contention = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.invalidVirtualMachineConfiguration.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
            ])
        let unwrapped = VirtualizationFailure.unwrappedRestoreFailure(
            VirtualizationError.restoreFailed(underlying: contention))
        #expect(VirtualizationFailure.isFileLockContention(unwrapped))

        // A non-wrapper error passes through unchanged.
        let passthrough = VirtualizationFailure.unwrappedRestoreFailure(
            VirtualizationError.noSaveFile)
        #expect(passthrough is VirtualizationError)
        #expect(!VirtualizationFailure.isRestoreFailure(passthrough))

        // The CustomNSError bridge leaves the other cases' descriptions alone.
        #expect(VirtualizationError.noSaveFile.localizedDescription == "No saved state file found.")
    }

    @Test("isRestoreFailure matches only restoreFailed")
    func isRestoreFailureMatchesOnlyRestoreFailed() {
        let restoreFailed = VirtualizationError.restoreFailed(
            underlying: NSError(
                domain: VZError.errorDomain, code: VZError.Code.internalError.rawValue))
        #expect(VirtualizationFailure.isRestoreFailure(restoreFailed))
        #expect(!VirtualizationFailure.isRestoreFailure(VirtualizationError.noSaveFile))
        #expect(
            !VirtualizationFailure.isRestoreFailure(
                NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))))
    }

    @Test("start sets error status for permanent config error")
    func startSetsErrorForPermanentConfigError() async throws {
        let instance = VMInstanceFixture.make(phase: .stopped)

        // start() fails at buildConfiguration (no real disk image) with a
        // ConfigurationBuilderError — a permanent error. The transient path
        // is covered by the isTransientStartError unit tests above.
        await #expect(throws: (any Error).self) {
            try await start(instance)
        }
        #expect(instance.status == .error)
        #expect(instance.errorMessage != nil)
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
