import Testing
import Foundation
import Virtualization
import KernovaTestSupport
@testable import Kernova

@Suite("VirtualizationService Tests", .admissionGated)
@MainActor
struct VirtualizationServiceTests {
    private let service = VirtualizationService(
        vmnetNetworks: MockVmnetNetworkProvider(), entitlements: .unentitled)

    // MARK: - Snapshot capture

    @Test("A capture puts a running guest back to running")
    func captureResumesAGuestItPaused() async throws {
        let session = MockSnapshotSession(guestState: .running)
        var stateWhileCapturing: MockSnapshotSession.GuestState?

        try await VirtualizationService.captureLiveState(
            session: session, wasRunning: true,
            saveFileURL: URL(filePath: "/tmp/save.vzvmsave")
        ) {
            stateWhileCapturing = await session.guestState
        }

        #expect(stateWhileCapturing == .paused)
        let finalState = await session.guestState
        #expect(finalState == .running)
    }

    @Test("A capture of a guest the user already paused leaves it paused")
    func captureLeavesAnAlreadyPausedGuestPaused() async throws {
        // `resumeIfPaused` resumes whatever is paused, so an unconditional call
        // here restarts the guest while the VM is reported as paused.
        let session = MockSnapshotSession(guestState: .paused)

        try await VirtualizationService.captureLiveState(
            session: session, wasRunning: false,
            saveFileURL: URL(filePath: "/tmp/save.vzvmsave")
        ) {}

        let finalState = await session.guestState
        let calls = await session.calls
        #expect(finalState == .paused)
        #expect(!calls.contains("resumeIfPaused"))
    }

    @Test("A capture that fails to save never copies the disks")
    func captureStopsAtAFailedSave() async {
        let session = MockSnapshotSession(guestState: .running)
        await session.setSaveError(VMSnapshotError.snapshotMissingSavedState)
        var captured = false

        await #expect(throws: VMSnapshotError.self) {
            try await VirtualizationService.captureLiveState(
                session: session, wasRunning: true,
                saveFileURL: URL(filePath: "/tmp/save.vzvmsave")
            ) { captured = true }
        }

        #expect(!captured)
    }

    // MARK: - Detaching passthrough accessories before a save

    /// A live session holding `count` passthrough accessories.
    private func instanceHoldingAccessories(_ count: Int) -> (VMInstance, UUID, [UUID]) {
        let sessionID = UUID()
        let instance = VMInstanceFixture.make(phase: .running(sessionID: sessionID))
        let context = instance.beginSessionContextForTesting()
        var deviceIDs: [UUID] = []
        for index in 0..<count {
            let deviceID = UUID()
            deviceIDs.append(deviceID)
            context.liveUSBAccessories.append(
                AttachedUSBAccessory(
                    deviceID: deviceID,
                    accessory: MockUSBAccessoryService.accessory(
                        registryID: UInt64(index + 1), serial: "SER\(index)")))
        }
        return (instance, sessionID, deviceIDs)
    }

    @Test("Every passthrough accessory is detached, and its tracking entry cleared")
    func detachesEveryAccessoryBeforeSaving() async throws {
        let (instance, sessionID, deviceIDs) = instanceHoldingAccessories(2)
        let session = MockSnapshotSession(guestState: .running)

        try await VirtualizationService.detachUSBAccessories(
            from: instance, session: session, for: sessionID)

        let detached = await session.detachedUSBDeviceIDs
        #expect(detached == deviceIDs)
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    @Test("A device the controller already lost clears its entry and does not fail the save")
    func anAlreadyDetachedDeviceIsNotAFailure() async throws {
        let (instance, sessionID, _) = instanceHoldingAccessories(1)
        let session = MockSnapshotSession(guestState: .running)
        await session.setDetachError(VMSessionError.usbDeviceNotFound)

        try await VirtualizationService.detachUSBAccessories(
            from: instance, session: session, for: sessionID)

        #expect(instance.liveUSBAccessories.isEmpty)
    }

    @Test("A detach that fails for any other reason stops the save rather than writing state")
    func aFailedDetachStopsTheSave() async {
        let (instance, sessionID, _) = instanceHoldingAccessories(1)
        let session = MockSnapshotSession(guestState: .running)
        await session.setDetachError(VMSessionError.usbControllerUnavailable)

        // Swallowing this would write a saved state still carrying a
        // passthrough device — a file `VZErrorRestore` refuses and nothing can
        // recover, produced by an operation that reported success.
        await #expect(throws: VMSessionError.self) {
            try await VirtualizationService.detachUSBAccessories(
                from: instance, session: session, for: sessionID)
        }

        let calls = await session.calls
        #expect(!calls.contains("saveMachineState"))
        #expect(instance.liveUSBAccessories.count == 1)
    }

    @Test("A sweep that throws part-way leaves only what it never reached attached")
    func aPartialSweepClearsWhatItEjected() async {
        let (instance, sessionID, deviceIDs) = instanceHoldingAccessories(2)
        let session = MockSnapshotSession(guestState: .running)
        await session.setDetachError(
            VMSessionError.usbControllerUnavailable, forDeviceID: deviceIDs[1])

        await #expect(throws: VMSessionError.self) {
            try await VirtualizationService.detachUSBAccessories(
                from: instance, session: session, for: sessionID)
        }

        // What the instance still holds is what the sweep never got to, which
        // is how the put-back after a failed capture knows what was ejected.
        #expect(instance.liveUSBAccessories.map(\.deviceID) == [deviceIDs[1]])
    }

    @Test("A session holding nothing asks VZ for no detach at all")
    func noAccessoriesMeansNoDetachCalls() async throws {
        let (instance, sessionID, _) = instanceHoldingAccessories(0)
        let session = MockSnapshotSession(guestState: .running)

        try await VirtualizationService.detachUSBAccessories(
            from: instance, session: session, for: sessionID)

        let calls = await session.calls
        #expect(calls.isEmpty)
    }

    @Test("A detach for a session that is no longer live leaves the live one alone")
    func detachForAStaleSessionDropsItsWrites() async throws {
        let (instance, _, _) = instanceHoldingAccessories(1)
        let session = MockSnapshotSession(guestState: .running)

        try await VirtualizationService.detachUSBAccessories(
            from: instance, session: session, for: UUID())

        // The device still left the controller — VZ was asked — but the record
        // belongs to whichever session is live now, so it is untouched.
        let detached = await session.detachedUSBDeviceIDs
        #expect(detached.count == 1)
        #expect(instance.liveUSBAccessories.count == 1)
    }

    // MARK: - A bring-up that fails before its session is live

    @Test("A bring-up that fails with a session context open rests the VM and releases the context")
    func failedBringUpRestsTheVMAndReleasesItsContext() async {
        let instance = VMInstanceFixture.make(phase: .stopped)
        struct GuestStopped: LocalizedError {
            var errorDescription: String? { "The guest stopped." }
        }

        await #expect(throws: GuestStopped.self) {
            try await instance.activity.bringUp(.guestStart(.starting(recovery: false))) {
                (context: borrowing VMBringUpContext) -> VMOperationEnding<Void> in
                instance.beginSessionContextForTesting()
                context.bindSessionForTesting(UUID())
                throw GuestStopped()
            }
        }

        #expect(instance.phase == .failed(message: "The guest stopped."))
        #expect(instance.sessionContext == nil)
    }

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
        defer { VMInstanceFixture.removeBundle(of: instance) }
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

    @Test("A guest that goes away mid-suspend drops the slot and rests where its end put it")
    func suspendOverAVanishingGuestDropsTheSlot() async throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        defer { VMInstanceFixture.removeBundle(of: instance) }
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
        let movedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Moved-\(UUID().uuidString).kernova", isDirectory: true)
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
        defer {
            try? FileManager.default.removeItem(at: original.bundleURL)
            try? FileManager.default.removeItem(at: moved.url)
        }
        let session = MockSnapshotSession(guestState: .running)
        await session.setSaveError(NSError(domain: "test", code: 1))

        await #expect(throws: (any Error).self) {
            try await instance.activity.perform(.saving) { context in
                instance.rebind(to: moved)
                return try await VirtualizationService.save(instance, context, session: session)
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
        defer {
            try? FileManager.default.removeItem(at: original.bundleURL)
            try? FileManager.default.removeItem(at: moved.url)
        }
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
            try await VirtualizationService.save(instance, context, session: session)
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
        defer {
            try? FileManager.default.removeItem(at: original.bundleURL)
            try? FileManager.default.removeItem(at: moved.url)
        }
        let session = MockSnapshotSession(guestState: .paused)
        await session.setAfterRestore {
            await MainActor.run { instance.rebind(to: moved) }
        }

        try await instance.activity.startGuest(.restoringSavedState) { context in
            try await VirtualizationService.restoreSavedState(
                instance, context.bringUp.operation, session: session)
            context.bringUp.bindSessionForTesting(UUID())
            return .rest(.live(.running), ())
        }

        #expect(await session.restoredStateURLs == [original.saveFileURL])
        #expect(!movedLayout.hasSaveFile)
        #expect(original.hasSaveFile)
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
        try await instance.activity.perform(.capturingSnapshot(.live)) { context in
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
        store.captureError = VMSnapshotError.snapshotMissingSavedState

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
        machineFiles: (any VMBundleMachineFileWorking)? = nil
    ) throws -> RevertFixture {
        let snapshot = VMSnapshot(name: "Before the update", kind: kind, macAddress: nil)
        let instance = try VMInstanceFixture.makeOnDisk(
            name: "Revert VM", phase: phase, snapshots: VMSnapshotManifest(snapshots: [snapshot]),
            bundleFactory: machineFiles.map(VMBundle.Factory.init(machineFiles:))
        ) {
            $0.memorySizeInGB = 16
            $0.macAddress = macAddress
        }
        let layout = instance.bundleLayout
        try Data("live-disk".utf8).write(to: layout.diskImageURL)

        // The capture: taken while the VM had 8 GB and a second disk.
        var capturedConfiguration = instance.configuration
        capturedConfiguration.memorySizeInGB = 8
        capturedConfiguration.macAddress = capturedMACAddress ?? macAddress
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
            library: makeWiredLibrary(holding: [instance]))
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
        return try await instance.activity.captureSnapshot(mode) { context in
            try await service.takeSnapshot(instance, context, snapshot: snapshot)
        }
    }

    @Test("A revert installs the configuration the snapshot captured, keeping identity")
    func revertInstallsTheCapturedConfiguration() async throws {
        let fixture = try makeRevertFixture()
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        let originalID = fixture.instance.configuration.id

        try await revert(fixture)

        #expect(fixture.instance.configuration.memorySizeInGB == 8)
        #expect(fixture.instance.configuration.id == originalID)
        #expect(fixture.instance.configuration.name == "Revert VM")
        // On disk too, so a later load reads the same settings the saved state
        // was written under.
        let written = try VMConfiguration.load(fromBundle: fixture.instance.bundleURL)
        #expect(written.memorySizeInGB == 8)
        #expect(written.name == "Revert VM")
    }

    @Test("A revert restores a disk the VM no longer configures")
    func revertRestoresADiskDroppedSinceTheCapture() async throws {
        let fixture = try makeRevertFixture()
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
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
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
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
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        let snapshot = VMSnapshotCaptureRequest(name: "Before first boot")

        let captured = try await capture(fixture.instance, snapshot)

        #expect(captured.id == snapshot.id)
        #expect(captured.kind == .cold)
        #expect(captured.macAddress == "aa:bb:cc:dd:ee:03")
        let written = try VMConfiguration.load(
            fromBundle: fixture.instance.bundleLayout.snapshotLayout(id: snapshot.id).bundleURL)
        #expect(written.macAddress == captured.macAddress)
    }

    @Test("An incomplete snapshot is refused before the live VM is torn down")
    func revertRefusesBeforeTearingTheVMDown() async throws {
        let fixture = try makeRevertFixture(phase: .running(sessionID: UUID()))
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
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
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        store.setCapturedConfiguration(fixture.capturedConfiguration, for: fixture.snapshot.id)
        store.stageError = VMSnapshotError.snapshotMissingFile("Disk.asif")

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
        #expect(fixture.instance.configuration.memorySizeInGB == 16)
    }

    /// The text of the file at `url`, `nil` when there is none.
    private func contents(of url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("A revert whose configuration commit fails leaves the disks and suspend slot untouched")
    func revertWhoseCommitFailsTouchesNoFile() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        let layout = fixture.instance.bundleLayout
        try Data("own-suspend-slot".utf8).write(to: layout.saveFileURL)
        struct CommitFailed: Error {}

        await #expect(throws: CommitFailed.self) {
            try await revert(fixture) { _, _ in throw CommitFailed() }
        }

        #expect(contents(of: layout.diskImageURL) == "live-disk")
        #expect(contents(of: layout.saveFileURL) == "own-suspend-slot")
        #expect(fixture.instance.configuration.memorySizeInGB == 16)
        #expect(!FileManager.default.fileExists(atPath: layout.restoreStagingURL.path(percentEncoded: false)))
        #expect(fixture.instance.phase == .suspended)
    }

    @Test("A revert commits the configuration before any file is swapped")
    func revertCommitsBeforeSwappingAnyFile() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
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
        #expect(fixture.instance.configuration.memorySizeInGB == 8)
    }

    /// Nothing rolls back: the swap is renames on one volume, and the disks it
    /// replaced are what the user chose to discard.
    @Test(
        "A revert whose install fails after the commit leaves the snapshot's configuration committed and no save file, and surfaces the error"
    )
    func revertWhoseInstallFailsLeavesTheCommittedConfigurationAndNoSaveFile() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
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

        #expect(fixture.instance.configuration.memorySizeInGB == 8)
        #expect(try VMConfiguration.load(fromBundle: fixture.instance.bundleURL).memorySizeInGB == 8)
        #expect(contents(of: layout.diskImageURL) == "captured-disk")
        #expect(!layout.hasSaveFile)
        #expect(fixture.instance.status == .stopped)
    }

    // MARK: - Disks-only snapshots

    @Test("A disks-only capture of a stopped VM writes the disks, no saved state, and rests stopped")
    func coldCaptureWritesDisksAndRestsStopped() async throws {
        let fixture = try makeRevertFixture()
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
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
        "A suspended-state capture clones the suspend slot and the disks, leaves the bundle's slot in place, and rests paused"
    )
    func suspendedCaptureClonesTheSlotAndRestsPaused() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        #expect(fixture.instance.isColdPaused)
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
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
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

    @Test("A cold-paused VM with no save file offers no capture and is refused one")
    func suspendedCaptureNeedsASaveFile() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        #expect(fixture.instance.isColdPaused)
        #expect(!fixture.instance.hasSaveFile)
        #expect(fixture.instance.snapshotCaptureMode == nil)

        await #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) {
            try await fixture.instance.activity.captureSnapshot(.suspended) { context in
                try await service.takeSnapshot(
                    fixture.instance, context,
                    snapshot: VMSnapshotCaptureRequest(name: "No slot"))
            }
        }
        #expect(fixture.instance.phase == .suspended)
    }

    @Test("Reverting to a suspended-state capture restores the cloned suspend slot and disks")
    func revertRoundTripsASuspendedCapture() async throws {
        let fixture = try makeRevertFixture(phase: .suspended)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        #expect(fixture.instance.isColdPaused)
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

    @Test("Reverting a live VM to a disks-only snapshot lands it stopped, with no resume")
    func coldRevertOfALiveVMLandsStopped() async throws {
        let fixture = try makeRevertFixture(phase: .running(sessionID: UUID()), kind: .cold)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }

        try await revert(fixture)

        #expect(fixture.instance.status == .stopped)
        #expect(!fixture.instance.bundleLayout.hasSaveFile)
        let restored = try Data(contentsOf: fixture.instance.bundleLayout.diskImageURL)
        #expect(String(decoding: restored, as: UTF8.self) == "captured-disk")
    }

    @Test("Reverting a suspended VM to a disks-only snapshot clears its suspend slot")
    func coldRevertClearsTheSuspendSlot() async throws {
        let fixture = try makeRevertFixture(phase: .suspended, kind: .cold)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        try Data("stale-suspend".utf8).write(to: fixture.instance.bundleLayout.saveFileURL)

        try await revert(fixture)

        #expect(fixture.instance.status == .stopped)
        #expect(!fixture.instance.bundleLayout.hasSaveFile)
    }

    // MARK: - Start

    /// Brings `instance` up by `kind` inside the bring-up the VM admits,
    /// running the real start body.
    private func start(
        _ instance: VMInstance, _ kind: VMGuestStartKind = .starting(recovery: false)
    ) async throws {
        _ = try await instance.activity.startGuest(kind) { context in
            try await service.start(instance, context, provisioning: nil)
        }
    }

    /// A bring-up that gives up before the restore leaves the slot for the
    /// next one.
    @Test("A restore of a VM holding a saved state keeps the slot when it fails")
    func startOfASuspendedVMRestoresAndKeepsTheSlot() async throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)

        // The bundle holds no real disk image, so the attempt fails at the
        // configuration build — past admission, and before the restore.
        await #expect(throws: (any Error).self) {
            try await start(instance, .restoringSavedState)
        }

        #expect(instance.hasSaveFile)
        #expect(instance.isColdPaused)
        #expect(instance.errorMessage == nil)
    }

    // MARK: - Duplicate Identity at Bring-Up

    /// Two VMs on one MAC address and network, in one wired library, with the
    /// first live — the refusal both bring-up tests below expect.
    private func makeLiveMACPair(
        restingAt phase: VMLifecyclePhase
    ) -> (library: VMLibrary, resting: VMInstance, live: VMInstance) {
        let resting = VMInstanceFixture.make(name: "Resting", phase: phase) {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:40"
        }
        let live = VMInstanceFixture.make(name: "Live", phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:40"
        }
        return (makeWiredLibrary(holding: [resting, live]), resting, live)
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
        defer { VMInstanceFixture.removeBundle(of: resting) }
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

    @Test("VM limit exceeded error is transient")
    func vmLimitExceededIsTransient() {
        let error = makeVMLimitExceededError()
        #expect(VirtualizationService.isVirtualMachineLimitExceeded(error))
        #expect(VirtualizationService.isTransientStartError(error))
    }

    @Test("VM limit exceeded under an installation failure is transient")
    func nestedVMLimitExceededIsTransient() {
        let error = makeInstallVMLimitExceededError()
        #expect(VirtualizationService.isVirtualMachineLimitExceeded(error))
        #expect(VirtualizationService.isTransientStartError(error))
    }

    @Test("VM limit exceeded is found anywhere within the bounded chain")
    func deeplyNestedVMLimitExceededIsFound() {
        for depth in 2...4 {
            let error = makeVZErrorChain(depth: depth, around: makeVMLimitExceededError())
            #expect(VirtualizationService.isVirtualMachineLimitExceeded(error))
            #expect(VirtualizationService.isTransientStartError(error))
        }
    }

    @Test("VM limit exceeded past the chain bound is not recognized")
    func vmLimitExceededBeyondBoundIsPermanent() {
        let error = makeVZErrorChain(depth: 5, around: makeVMLimitExceededError())
        #expect(!VirtualizationService.isVirtualMachineLimitExceeded(error))
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("An installation failure carrying no underlying error is permanent")
    func installationFailedAloneIsPermanent() {
        let error = NSError(
            domain: VZError.errorDomain, code: VZError.Code.installationFailed.rawValue)
        #expect(!VirtualizationService.isVirtualMachineLimitExceeded(error))
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("A builder error wrapping the VM limit stays permanent")
    func builderErrorWrappingLimitIsPermanent() {
        let wrapped = ConfigurationBuilderError.storageDiskAttachFailed(
            id: UUID(), path: "/tmp/Disk.asif", label: "Main Disk",
            underlying: makeVMLimitExceededError())
        #expect(!VirtualizationService.isTransientStartError(wrapped))
    }

    @Test("A nested operation cancelled is not transient")
    func nestedOperationCancelledIsPermanent() {
        let error = makeVZErrorChain(
            depth: 1,
            around: NSError(
                domain: VZError.errorDomain, code: VZError.Code.operationCancelled.rawValue))
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("The underlying chain description names every link, bounded")
    func underlyingChainDescriptionNamesEveryLink() {
        #expect(
            VirtualizationService.underlyingChainDescription(makeInstallVMLimitExceededError())
                == "\(VZError.errorDomain) \(VZError.Code.virtualMachineLimitExceeded.rawValue)")
        #expect(
            VirtualizationService.underlyingChainDescription(makeVMLimitExceededError()) == "none")
        let deep = makeVZErrorChain(depth: 6, around: makeVMLimitExceededError())
        #expect(
            VirtualizationService.underlyingChainDescription(deep)
                .components(separatedBy: " → ").count == 4)
    }

    @Test("operation cancelled error is transient")
    func operationCancelledIsTransient() {
        let error = NSError(domain: VZError.errorDomain, code: VZError.Code.operationCancelled.rawValue)
        #expect(VirtualizationService.isTransientStartError(error))
    }

    @Test("invalid VM configuration error is permanent")
    func invalidConfigurationIsPermanent() {
        let error = NSError(domain: VZError.errorDomain, code: VZError.Code.invalidVirtualMachineConfiguration.rawValue)
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("internal VZ error is permanent")
    func internalVZErrorIsPermanent() {
        let error = NSError(domain: VZError.errorDomain, code: VZError.Code.internalError.rawValue)
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("configuration builder error is permanent")
    func configBuilderErrorIsPermanent() {
        let error = ConfigurationBuilderError.missingKernelPath
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("unknown domain error is permanent")
    func unknownDomainIsPermanent() {
        let error = NSError(domain: "SomeOtherDomain", code: 42)
        #expect(!VirtualizationService.isTransientStartError(error))
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
        #expect(VirtualizationService.isFileLockContention(makeFileLockContentionError()))
    }

    @Test("file-lock contention is a transient start error")
    func fileLockContentionIsTransient() {
        #expect(VirtualizationService.isTransientStartError(makeFileLockContentionError()))
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
        #expect(VirtualizationService.isFileLockContention(wrapped))
        #expect(VirtualizationService.isTransientStartError(wrapped))
    }

    @Test("wrapped removable media lock contention is transient")
    func wrappedRemovableMediaLockContentionIsTransient() {
        let wrapped = ConfigurationBuilderError.removableMediaAttachFailed(
            id: UUID(), path: "/tmp/install.iso", label: "Installer",
            underlying: makeFileLockContentionError())
        #expect(VirtualizationService.isFileLockContention(wrapped))
        #expect(VirtualizationService.isTransientStartError(wrapped))
    }

    @Test("a non-contention attach failure stays permanent")
    func wrappedNonContentionAttachFailureIsPermanent() {
        // The sandbox-denied-open case: real, not transient, and must keep
        // landing the VM in .error rather than being retried as contention.
        let wrapped = ConfigurationBuilderError.storageDiskAttachFailed(
            id: UUID(), path: "/tmp/Disk.asif", label: "Main Disk",
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))
        #expect(!VirtualizationService.isFileLockContention(wrapped))
        #expect(!VirtualizationService.isTransientStartError(wrapped))
    }

    @Test("invalid configuration without underlying error is not lock contention")
    func invalidConfigurationAloneIsNotLockContention() {
        let error = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.invalidVirtualMachineConfiguration.rawValue)
        #expect(!VirtualizationService.isFileLockContention(error))
    }

    @Test("invalid configuration with non-EAGAIN underlying error is not lock contention")
    func nonEAGAINUnderlyingIsNotLockContention() {
        let error = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.invalidVirtualMachineConfiguration.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            ])
        #expect(!VirtualizationService.isFileLockContention(error))
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("EAGAIN under a different VZ code is not lock contention")
    func eagainUnderOtherVZCodeIsNotLockContention() {
        let error = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.internalError.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
            ])
        #expect(!VirtualizationService.isFileLockContention(error))
    }

    @Test("top-level POSIX EAGAIN is not lock contention")
    func topLevelEAGAINIsNotLockContention() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
        #expect(!VirtualizationService.isFileLockContention(error))
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
        defer { VMInstanceFixture.removeBundle(of: holding) }

        holding.activity.placeForTesting(holding.restingPhase(withoutSlot: .stopped))

        #expect(holding.status == .paused)
        #expect(holding.isColdPaused)
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
        _ = try? await instance.activity.bringUp(kind) {
            (_: borrowing VMBringUpContext) -> VMOperationEnding<Void> in
            throw error
        }
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
            defer { VMInstanceFixture.removeBundle(of: instance) }
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
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)
        #expect(
            await restAfterFailedBringUp(
                .reverting(snapshotID: snapshot.id, resumesAfter: true), on: instance,
                with: VirtualizationError.revertResumeFailed(
                    underlying: ConfigurationBuilderError.sharedDirectoryNotFound("/gone")))
                == .suspended)
    }

    @Test("classifiers see through the restoreFailed wrapper")
    func classifiersSeeThroughRestoreFailedWrapper() {
        let limit = NSError(
            domain: VZError.errorDomain, code: VZError.Code.virtualMachineLimitExceeded.rawValue)
        #expect(
            VirtualizationService.isVirtualMachineLimitExceeded(
                VirtualizationError.restoreFailed(underlying: limit)))

        let contention = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.invalidVirtualMachineConfiguration.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
            ])
        let unwrapped = VirtualizationService.unwrappedRestoreFailure(
            VirtualizationError.restoreFailed(underlying: contention))
        #expect(VirtualizationService.isFileLockContention(unwrapped))

        // A non-wrapper error passes through unchanged.
        let passthrough = VirtualizationService.unwrappedRestoreFailure(
            VirtualizationError.noSaveFile)
        #expect(passthrough is VirtualizationError)
        #expect(!VirtualizationService.isRestoreFailure(passthrough))

        // The CustomNSError bridge leaves the other cases' descriptions alone.
        #expect(VirtualizationError.noSaveFile.localizedDescription == "No saved state file found.")
    }

    @Test("isRestoreFailure matches only restoreFailed")
    func isRestoreFailureMatchesOnlyRestoreFailed() {
        let restoreFailed = VirtualizationError.restoreFailed(
            underlying: NSError(
                domain: VZError.errorDomain, code: VZError.Code.internalError.rawValue))
        #expect(VirtualizationService.isRestoreFailure(restoreFailed))
        #expect(!VirtualizationService.isRestoreFailure(VirtualizationError.noSaveFile))
        #expect(
            !VirtualizationService.isRestoreFailure(
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootHeal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let picked = directory.appendingPathComponent("Picked.kernel")
        try Data("kernel".utf8).write(to: picked)
        let bookmark = try #require(SecurityScopedBookmark.make(for: picked))
        // Moved since the pick, so only the bookmark still finds it.
        try FileManager.default.moveItem(
            at: picked, to: directory.appendingPathComponent("Moved.kernel"))
        let instance = VMInstanceFixture.make(phase: .stopped) {
            $0.bootMode = .linuxKernel
            $0.kernelPath = picked.path(percentEncoded: false)
            $0.kernelBookmark = bookmark
        }
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

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
}
