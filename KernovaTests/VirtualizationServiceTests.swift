import Testing
import Foundation
import Virtualization
@testable import Kernova

@Suite("VirtualizationService Tests", .admissionGated)
@MainActor
struct VirtualizationServiceTests {
    private let service = VirtualizationService()

    private func makeInstance(status: VMStatus = .stopped) -> VMInstance {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

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

    // MARK: - Snapshot revert

    /// A bundle holding one snapshot's captured disk, saved state and
    /// configuration, plus the VM's own files.
    private struct RevertFixture {
        let instance: VMInstance
        let snapshot: VMSnapshot
        let store: VMSnapshotStore
        /// What the snapshot recorded, which the revert has to install.
        let capturedConfiguration: VMConfiguration
    }

    private func makeRevertFixture(
        status: VMStatus = .stopped, kind: VMSnapshotKind = .warm
    ) throws -> RevertFixture {
        var config = VMConfiguration(name: "Revert VM", guestOS: .linux, bootMode: .efi)
        config.memorySizeInGB = 16
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevertTests-\(UUID().uuidString)", isDirectory: true)
        let layout = VMBundleLayout(bundleURL: bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("live-disk".utf8).write(to: layout.diskImageURL)

        // The capture: taken while the VM had 8 GB and a second disk.
        var capturedConfiguration = config
        capturedConfiguration.memorySizeInGB = 8
        let extraID = UUID()
        capturedConfiguration.storageDisks = [
            StorageDisk(path: "Disk.asif", isInternal: true),
            StorageDisk(
                id: extraID, path: "AdditionalDisks/\(extraID.uuidString).asif", isInternal: true),
        ]
        let snapshot = VMSnapshot(name: "Before the update", kind: kind)
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

        // The VM as it stands now: more memory, and the second disk removed.
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: status)
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])
        return RevertFixture(
            instance: instance, snapshot: snapshot, store: VMSnapshotStore(),
            capturedConfiguration: capturedConfiguration)
    }

    @Test("A revert installs the configuration the snapshot captured, keeping identity")
    func revertInstallsTheCapturedConfiguration() async throws {
        let fixture = try makeRevertFixture()
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        let originalID = fixture.instance.configuration.id

        try await service.revertToSnapshot(
            fixture.instance, snapshot: fixture.snapshot, store: fixture.store)

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

        try await service.revertToSnapshot(
            fixture.instance, snapshot: fixture.snapshot, store: fixture.store)

        let restoredExtra = layout.bundleURL.appendingPathComponent(extraPath)
        #expect(FileManager.default.fileExists(atPath: restoredExtra.path(percentEncoded: false)))
        let mainDisk = try Data(contentsOf: layout.diskImageURL)
        #expect(String(decoding: mainDisk, as: UTF8.self) == "captured-disk")
    }

    @Test("An incomplete snapshot is refused before the live VM is torn down")
    func revertRefusesBeforeTearingTheVMDown() async throws {
        let fixture = try makeRevertFixture(status: .running)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        fixture.instance.hasLiveVirtualMachineOverrideForTesting = true
        // The snapshot loses the file its own configuration names, so the
        // pre-flight refuses.
        let snapshotLayout = fixture.instance.bundleLayout.snapshotLayout(id: fixture.snapshot.id)
        try FileManager.default.removeItem(at: snapshotLayout.diskImageURL)

        await #expect(throws: VMSnapshotError.self) {
            try await service.revertToSnapshot(
                fixture.instance, snapshot: fixture.snapshot, store: fixture.store)
        }

        // Untouched: no `.restoring`, no resting status applied, and the VM's
        // own disk still holds what the live guest wrote.
        #expect(fixture.instance.status == .running)
        let liveDisk = try Data(contentsOf: fixture.instance.bundleLayout.diskImageURL)
        #expect(String(decoding: liveDisk, as: UTF8.self) == "live-disk")
    }

    // MARK: - Disks-only snapshots

    @Test("A disks-only capture of a stopped VM writes the disks, no saved state, and rests stopped")
    func coldCaptureWritesDisksAndRestsStopped() async throws {
        let fixture = try makeRevertFixture()
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        let snapshot = VMSnapshot(name: "Before first boot", kind: .cold)

        try await service.takeSnapshot(
            fixture.instance, snapshot: snapshot, store: fixture.store)

        let snapshotLayout = fixture.instance.bundleLayout.snapshotLayout(id: snapshot.id)
        let captured = try Data(contentsOf: snapshotLayout.diskImageURL)
        #expect(String(decoding: captured, as: UTF8.self) == "live-disk")
        #expect(!snapshotLayout.hasSaveFile)
        #expect(fixture.instance.status == .stopped)
    }

    @Test("A memory-and-disks capture with no live session is refused")
    func warmCaptureNeedsASession() async throws {
        let fixture = try makeRevertFixture()
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }

        await #expect(throws: VirtualizationError.self) {
            try await service.takeSnapshot(
                fixture.instance, snapshot: VMSnapshot(name: "No session", kind: .warm),
                store: fixture.store)
        }
        #expect(fixture.instance.status == .stopped)
    }

    @Test("A disks-only capture of a running VM is refused")
    func coldCaptureNeedsAStoppedVM() async throws {
        let fixture = try makeRevertFixture(status: .running)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        fixture.instance.hasLiveVirtualMachineOverrideForTesting = true

        await #expect(throws: VirtualizationError.self) {
            try await service.takeSnapshot(
                fixture.instance, snapshot: VMSnapshot(name: "Still live", kind: .cold),
                store: fixture.store)
        }
        #expect(fixture.instance.status == .running)
    }

    @Test("Reverting a live VM to a disks-only snapshot lands it stopped, with no resume")
    func coldRevertOfALiveVMLandsStopped() async throws {
        let fixture = try makeRevertFixture(status: .running, kind: .cold)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        fixture.instance.hasLiveVirtualMachineOverrideForTesting = true

        try await service.revertToSnapshot(
            fixture.instance, snapshot: fixture.snapshot, store: fixture.store)

        #expect(fixture.instance.status == .stopped)
        #expect(!fixture.instance.bundleLayout.hasSaveFile)
        let restored = try Data(contentsOf: fixture.instance.bundleLayout.diskImageURL)
        #expect(String(decoding: restored, as: UTF8.self) == "captured-disk")
    }

    @Test("Reverting a suspended VM to a disks-only snapshot clears its suspend slot")
    func coldRevertClearsTheSuspendSlot() async throws {
        let fixture = try makeRevertFixture(status: .paused, kind: .cold)
        defer { try? FileManager.default.removeItem(at: fixture.instance.bundleURL) }
        try Data("stale-suspend".utf8).write(to: fixture.instance.bundleLayout.saveFileURL)

        try await service.revertToSnapshot(
            fixture.instance, snapshot: fixture.snapshot, store: fixture.store)

        #expect(fixture.instance.status == .stopped)
        #expect(!fixture.instance.bundleLayout.hasSaveFile)
    }

    // MARK: - Start Guards

    @Test("start throws when VM is already running")
    func startThrowsWhenRunning() async {
        let instance = makeInstance(status: .running)

        await #expect(throws: VirtualizationError.self) {
            try await service.start(instance)
        }
    }

    @Test("start throws when VM is paused")
    func startThrowsWhenPaused() async {
        let instance = makeInstance(status: .paused)

        await #expect(throws: VirtualizationError.self) {
            try await service.start(instance)
        }
    }

    @Test("start throws when VM is starting")
    func startThrowsWhenStarting() async {
        let instance = makeInstance(status: .starting)

        await #expect(throws: VirtualizationError.self) {
            try await service.start(instance)
        }
    }

    // MARK: - Stop Guards

    @Test("stop throws when VM is stopped")
    func stopThrowsWhenStopped() async {
        let instance = makeInstance(status: .stopped)

        await #expect(throws: VirtualizationError.self) {
            try await service.stop(instance)
        }
    }

    @Test("stop throws when VM is starting")
    func stopThrowsWhenStarting() async {
        let instance = makeInstance(status: .starting)

        await #expect(throws: VirtualizationError.self) {
            try await service.stop(instance)
        }
    }

    // MARK: - Pause Guards

    @Test("pause throws when VM is stopped")
    func pauseThrowsWhenStopped() async {
        let instance = makeInstance(status: .stopped)

        await #expect(throws: VirtualizationError.self) {
            try await service.pause(instance)
        }
    }

    @Test("pause throws when VM is paused")
    func pauseThrowsWhenAlreadyPaused() async {
        let instance = makeInstance(status: .paused)

        await #expect(throws: VirtualizationError.self) {
            try await service.pause(instance)
        }
    }

    // MARK: - Resume Guards

    @Test("resume throws when VM is stopped")
    func resumeThrowsWhenStopped() async {
        let instance = makeInstance(status: .stopped)

        await #expect(throws: VirtualizationError.self) {
            try await service.resume(instance)
        }
    }

    @Test("resume throws when VM is running")
    func resumeThrowsWhenRunning() async {
        let instance = makeInstance(status: .running)

        await #expect(throws: VirtualizationError.self) {
            try await service.resume(instance)
        }
    }

    // MARK: - Save Guards

    @Test("save throws when VM is stopped")
    func saveThrowsWhenStopped() async {
        let instance = makeInstance(status: .stopped)

        await #expect(throws: VirtualizationError.self) {
            try await service.save(instance)
        }
    }

    // MARK: - ForceStop Guards

    @Test("forceStop throws when no virtual machine exists and not cold-paused")
    func forceStopThrowsWhenNoVM() async {
        let instance = makeInstance(status: .running)
        // No virtualMachine assigned, and not cold-paused (status is .running)

        await #expect(throws: VirtualizationError.self) {
            try await service.forceStop(instance)
        }
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

    // MARK: - Restore Failure

    @Test("a failed restore rests at cold-paused with the save file intact")
    func applyRestoreFailureRestsColdPausedKeepingSaveFile() throws {
        let instance = makeInstance(status: .restoring)
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        FileManager.default.createFile(
            atPath: instance.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))
        instance.errorMessage = "stale message"

        instance.tearDownSession()
        VirtualizationService.applyRestoreFailure(to: instance)

        #expect(instance.status == .paused)
        #expect(instance.isColdPaused)
        #expect(instance.errorMessage == nil)
        #expect(instance.hasSaveFile)
    }

    @Test("a failed restore with the save file already discarded rests stopped")
    func applyRestoreFailureWithoutSaveFileRestsStopped() {
        let instance = makeInstance(status: .restoring)
        instance.errorMessage = "stale message"

        VirtualizationService.applyRestoreFailure(to: instance)

        #expect(instance.status == .stopped)
        #expect(instance.errorMessage == nil)
    }

    @Test("applyLifecycleFailure dispatches by failure kind and entry point")
    func applyLifecycleFailureDispatches() throws {
        // A restore failure rests at cold-paused, regardless of entry point.
        let restored = makeInstance(status: .restoring)
        try FileManager.default.createDirectory(
            at: restored.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: restored.bundleURL) }
        FileManager.default.createFile(
            atPath: restored.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))
        VirtualizationService.applyLifecycleFailure(
            VirtualizationError.restoreFailed(underlying: NSError(domain: "test", code: 1)),
            to: restored, transientRestingStatus: .stopped)
        #expect(restored.status == .paused)

        // A permanent start failure lands in .error carrying the message.
        let started = makeInstance(status: .starting)
        VirtualizationService.applyLifecycleFailure(
            VirtualizationError.noVirtualMachine, to: started, transientRestingStatus: .stopped)
        #expect(started.status == .error)
        #expect(started.errorMessage != nil)

        // A transient start failure rests at the given status with no message.
        let transient = makeInstance(status: .starting)
        VirtualizationService.applyLifecycleFailure(
            NSError(domain: VZError.errorDomain, code: VZError.Code.operationCancelled.rawValue),
            to: transient, transientRestingStatus: .stopped)
        #expect(transient.status == .stopped)
        #expect(transient.errorMessage == nil)

        // A resume failure (no resting status) lands in .error with the message.
        let resumed = makeInstance(status: .paused)
        VirtualizationService.applyLifecycleFailure(
            VirtualizationError.noSaveFile, to: resumed, transientRestingStatus: nil)
        #expect(resumed.status == .error)
        #expect(resumed.errorMessage != nil)
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

    @Test("restoreFailed carries the underlying failure and the way forward")
    func restoreFailedDescriptionCarriesUnderlyingAndGuidance() {
        let underlying = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The save file is corrupted."])
        let description = VirtualizationError.restoreFailed(underlying: underlying)
            .localizedDescription
        #expect(description.contains("The save file is corrupted."))
        #expect(description.contains("Resume"))
        #expect(description.contains("Discard Saved State"))
    }

    @Test("start sets error status for permanent config error")
    func startSetsErrorForPermanentConfigError() async throws {
        let instance = makeInstance(status: .stopped)

        // start() fails at buildConfiguration (no real disk image) with a
        // ConfigurationBuilderError — a permanent error. The transient path
        // is covered by the isTransientStartError unit tests above.
        await #expect(throws: (any Error).self) {
            try await service.start(instance)
        }
        #expect(instance.status == .error)
        #expect(instance.errorMessage != nil)
    }
}
