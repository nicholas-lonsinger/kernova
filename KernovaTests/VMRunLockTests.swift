import Foundation
import KernovaKit
import KernovaTestSupport
import System
import Testing

@testable import Kernova

/// The cross-copy run lock on a VM's bundle directory: ``VMActivity`` holds it
/// exactly while the VM is neither at rest nor removed, takes it in the one
/// admission step, and refuses an operation another copy of Kernova holds the
/// bundle for before anything of the operation runs.
@Suite("VM run lock", .serialized, .caseScoped)
@MainActor
struct VMRunLockTests {
    private struct Probe: Error {}

    /// What the bodies under test saw, in place of captured mutable locals.
    @MainActor
    private final class Recorder {
        var bodyRan = false
        var heldInBody: Bool?
        var startedFrom: VMLifecyclePhase?
        var pendingSetupInBody: Bool?
        var heldInHook: Bool?
        var phaseInHook: VMLifecyclePhase?
        var heldAtAdmission: Bool?
        var revert: VMOutcome?
    }

    private static let baseline = VMSnapshot(name: "Baseline", macAddress: nil)

    /// A VM whose bundle lives in `store`, which the test reads and marks as
    /// held elsewhere.
    private func makeInstance(
        _ phase: VMLifecyclePhase = .stopped,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> (VMInstance, InMemoryVMBundleFiles) {
        let store = InMemoryVMBundleFiles()
        let instance = VMInstanceFixture.make(
            phase: phase, snapshots: VMSnapshotManifest(snapshots: [Self.baseline]), files: store,
            mutate: mutate)
        return (instance, store)
    }

    /// The invariant: this copy holds the lock exactly while the VM is neither
    /// at rest nor removed, and the store agrees.
    private func expectLockFollowsPhase(
        _ instance: VMInstance, _ store: InMemoryVMBundleFiles,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let phase = instance.phase
        let expected = !phase.isAtRest && phase != .removed
        #expect(instance.activity.holdsRunLock == expected, "\(phase)", sourceLocation: sourceLocation)
        #expect(
            store.isLockedByThisCopy(instance.bundleURL) == expected, "\(phase)",
            sourceLocation: sourceLocation)
    }

    /// Brings `instance` up live through a real bring-up.
    private func startLive(_ instance: VMInstance) async throws {
        try await instance.activity.launchStartGuest(.starting(recovery: false)) { context in
            context.bringUp.bindSessionForTesting(UUID())
            return .rest(.live(.running), ())
        }.value()
    }

    // MARK: - Refusal

    /// One operation entry point, begun from the phase it is admitted from.
    private struct Attempt: Sendable, CustomStringConvertible {
        let description: String
        let phase: VMLifecyclePhase
        var slot = false
        var pendingSetup = false
        let run: @MainActor @Sendable (VMInstance, Recorder) async throws -> Void
    }

    nonisolated private static let attempts: [Attempt] = [
        Attempt(description: "start", phase: .stopped) { instance, recorder in
            try await instance.activity.launchStartGuest(.starting(recovery: false)) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }.value()
        },
        Attempt(description: "restore", phase: .suspended, slot: true) { instance, recorder in
            try await instance.activity.launchStartGuest(.restoringSavedState) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }.value()
        },
        Attempt(description: "setup", phase: .initialBoot, pendingSetup: true) { instance, recorder in
            try instance.activity.launchBringUp(.settingUp(.linuxImageDownload)) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        },
        Attempt(description: "revert", phase: .stopped) { instance, recorder in
            try instance.activity.launchRevert(to: VMRunLockTests.baseline, resumesAfter: false) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        },
        Attempt(description: "capture", phase: .stopped) { instance, recorder in
            try await instance.activity.captureSnapshot(.stopped) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        },
        Attempt(description: "snapshot delete", phase: .stopped) { instance, recorder in
            try await instance.activity.perform(.deletingSnapshot) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        },
        Attempt(description: "discard saved state", phase: .suspended, slot: true) { instance, recorder in
            try instance.activity.performNow(.discardingSavedState) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        },
        Attempt(description: "disk create", phase: .stopped) { instance, recorder in
            try await instance.activity.perform(.creatingStorageDisk) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        },
        Attempt(description: "disk remove", phase: .stopped) { instance, recorder in
            try await instance.activity.perform(.removingStorageDisk) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        },
        Attempt(description: "media create", phase: .stopped) { instance, recorder in
            try await instance.activity.perform(.creatingRemovableMedia) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        },
        Attempt(description: "copy-out", phase: .stopped) { instance, recorder in
            try instance.activity.launch(.copyingOut) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        },
        Attempt(description: "delete", phase: .stopped) { instance, recorder in
            try await instance.activity.delete { _ in recorder.bodyRan = true }
        },
    ]

    @Test(
        "Every operation on a VM another copy holds is refused before its body runs",
        arguments: attempts.indices)
    func everyOperationIsRefusedWhileHeldElsewhere(index: Int) async throws {
        let attempt = Self.attempts[index]
        let (instance, store) = makeInstance(attempt.phase) {
            if attempt.pendingSetup {
                $0.linuxInstallContext = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
            }
        }
        if attempt.slot { try VMInstanceFixture.writeSaveFile(for: instance) }
        store.holdElsewhere(instance.bundleURL)
        let recorder = Recorder()

        await #expect(throws: VMAdmissionRefusal(refusal: .heldByAnotherCopy)) {
            try await attempt.run(instance, recorder)
        }

        #expect(!recorder.bodyRan)
        #expect(instance.phase == attempt.phase)
        #expect(instance.activity.heldByAnotherCopy)
        expectLockFollowsPhase(instance, store)
    }

    @Test("The same attempts are admitted, and let go of the lock, once no other copy holds the bundle")
    func everyAttemptIsAdmittedWhenFree() async throws {
        for attempt in Self.attempts {
            let (instance, store) = makeInstance(attempt.phase) {
                if attempt.pendingSetup {
                    $0.linuxInstallContext = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
                }
            }
            if attempt.slot { try VMInstanceFixture.writeSaveFile(for: instance) }
            let recorder = Recorder()
            try await attempt.run(instance, recorder)
            if let outcome = instance.phase.operation?.outcome { try await outcome.value() }
            #expect(recorder.bodyRan, "\(attempt)")
            expectLockFollowsPhase(instance, store)
        }
    }

    // MARK: - Invariant

    @Test("The lock is held exactly while the VM is neither at rest nor removed, after every commit and ending")
    func lockFollowsThePhaseThroughEveryTransition() async throws {
        let (instance, store) = makeInstance()
        let recorder = Recorder()
        expectLockFollowsPhase(instance, store)

        // A bring-up: held in the body, and while the guest runs.
        try await instance.activity.launchStartGuest(.starting(recovery: false)) { context in
            recorder.heldInBody = instance.activity.holdsRunLock
            context.bringUp.bindSessionForTesting(UUID())
            return .rest(.live(.running), ())
        }.value()
        #expect(recorder.heldInBody == true)
        expectLockFollowsPhase(instance, store)

        // Live operations keep it.
        try await instance.activity.perform(.pausing) { _ in .rest(.live(.paused), ()) }
        expectLockFollowsPhase(instance, store)
        try await instance.activity.perform(.resuming) { _ in .rest(.live(.running), ()) }
        expectLockFollowsPhase(instance, store)

        // A session ending rests the VM and lets it go.
        let sessionID = try #require(instance.liveSessionID)
        instance.deliverSessionEvent(.guestDidStop, from: sessionID)
        #expect(instance.phase == .stopped)
        expectLockFollowsPhase(instance, store)

        // A Force Stop's ending.
        try await startLive(instance)
        try await instance.activity.forceStop {}
        #expect(instance.phase == .stopped)
        expectLockFollowsPhase(instance, store)

        // A suspend that ends at rest.
        try await startLive(instance)
        try await instance.activity.perform(.saving) { _ in .rest(.atRest(.stopped), ()) }
        expectLockFollowsPhase(instance, store)

        // A re-read that fails after the lock is taken lets it go.
        let config = VMBundleLayout.configRelativePath
        store.setUnreadable(true, relativePath: config, at: instance.bundleURL)
        await #expect(throws: UnreadableBundleFile.self) {
            try await instance.activity.perform(.deletingSnapshot) { _ in .rest(.asStarted, ()) }
        }
        store.setUnreadable(false, relativePath: config, at: instance.bundleURL)
        expectLockFollowsPhase(instance, store)

        // A lock attempt that throws takes nothing.
        store.setLockError(Errno.noSuchFileOrDirectory, at: instance.bundleURL)
        await #expect(throws: Errno.noSuchFileOrDirectory) {
            try await instance.activity.perform(.deletingSnapshot) { _ in .rest(.asStarted, ()) }
        }
        store.setLockError(nil, at: instance.bundleURL)
        expectLockFollowsPhase(instance, store)

        // A body that throws.
        await #expect(throws: Probe.self) {
            try await instance.activity.perform(.creatingStorageDisk) {
                (_: borrowing VMOperationContext) throws -> VMOperationEnding<Void> in throw Probe()
            }
        }
        expectLockFollowsPhase(instance, store)

        // A bring-up that fails before binding a session.
        await #expect(throws: Probe.self) {
            try await instance.activity.launchStartGuest(.starting(recovery: false)) {
                (_: borrowing VMGuestStartContext) throws -> VMOperationEnding<Void> in throw Probe()
            }.value()
        }
        expectLockFollowsPhase(instance, store)

        // A launched operation, held across its whole body.
        let gate = GatedStep()
        let outcome = try instance.activity.launch(.copyingOut) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
        try await gate.waitUntilEntered()
        expectLockFollowsPhase(instance, store)
        gate.release()
        try await outcome.value()
        expectLockFollowsPhase(instance, store)

        // A refused admission keeps nothing.
        await #expect(throws: VMAdmissionRefusal.self) {
            try await instance.activity.perform(.pausing) { _ in .rest(.asStarted, ()) }
        }
        expectLockFollowsPhase(instance, store)

        // A delete removes the VM and lets it go.
        try await instance.activity.delete { _ in }
        #expect(instance.phase == .removed)
        expectLockFollowsPhase(instance, store)
    }

    @Test("A rebind replaces the bundle without letting go of the lock the VM holds")
    func rebindKeepsTheLock() async throws {
        let (instance, store) = makeInstance()
        try await startLive(instance)
        let lockedURL = instance.bundleURL

        instance.rebind(
            to: VMBundle.Factory(machineFiles: MockVMBundleMachineFiles(files: store))
                .make(VMInstanceFixture.read(lockedURL, from: store)))

        #expect(instance.activity.holdsRunLock)
        #expect(store.bundlesLockedByThisCopy == [lockedURL.standardizedFileURL])
    }

    // MARK: - Endings reuse the lock

    @Test("A power-off's Ephemeral revert follow-up is admitted under the lock the ending held")
    func powerOffRevertReusesTheLock() async throws {
        let (instance, store) = makeInstance()
        let recorder = Recorder()
        let gate = GatedStep()
        instance.activity.onPoweredOff = {
            recorder.heldInHook = instance.activity.holdsRunLock
            recorder.phaseInHook = instance.phase
            let revert = VMFollowUp(scope: .vm, rank: .restoration) { outcome in
                recorder.heldAtAdmission = instance.activity.holdsRunLock
                try instance.activity.launchRevert(
                    to: Self.baseline, resumesAfter: false, origin: .powerOffRevert,
                    resolving: outcome
                ) { _ in
                    try await gate.pass()
                    return .rest(.asStarted, ())
                }
            }
            recorder.revert = revert.outcome
            return [revert]
        }
        try await startLive(instance)

        let sessionID = try #require(instance.liveSessionID)
        instance.deliverSessionEvent(.guestDidStop, from: sessionID)

        // The store refuses a second lock on a bundle this copy holds, so the
        // revert was admitted only because it kept the one the ending held.
        #expect(recorder.phaseInHook == .stopped)
        #expect(recorder.heldInHook == true)
        #expect(recorder.heldAtAdmission == true)
        let revert = try #require(recorder.revert)
        guard case .bringUp(.reverting)? = instance.phase.operation?.kind else {
            Issue.record("The revert did not take the VM: \(instance.phase)")
            return
        }
        expectLockFollowsPhase(instance, store)
        gate.release()
        try await revert.value()
        #expect(instance.phase == .stopped)
        expectLockFollowsPhase(instance, store)
    }

    // MARK: - Re-read before the decision

    @Test("The admission re-reads the bundle before it decides: a setup another copy finished no longer blocks a start")
    func admissionDecidesOnTheReRead() async throws {
        let (instance, store) = makeInstance(.initialBoot) {
            $0.linuxInstallContext = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        }
        try VMStagedBundle.fixtureForTesting(at: instance.bundleURL, access: store)
            .update(.configuration) { $0.linuxInstallContext = nil }
        let recorder = Recorder()

        try await instance.activity.launchStartGuest(.starting(recovery: false)) { _ in
            recorder.startedFrom = instance.phase.operation?.startedFrom
            recorder.pendingSetupInBody = instance.configuration.pendingGuestSetup != nil
            return .rest(.asStarted, ())
        }.value()

        #expect(recorder.startedFrom == .stopped)
        #expect(recorder.pendingSetupInBody == false)
        #expect(instance.phase == .stopped)
        expectLockFollowsPhase(instance, store)
    }

    @Test("A save file another copy left re-derives the VM as suspended, and refuses a cold boot over it")
    func admissionSeesASaveFileAnotherCopyLeft() async throws {
        let (instance, store) = makeInstance(.stopped)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let recorder = Recorder()

        await #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) {
            try await instance.activity.launchStartGuest(.starting(recovery: false)) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }.value()
        }

        #expect(!recorder.bodyRan)
        #expect(instance.phase == .suspended)
        expectLockFollowsPhase(instance, store)
    }

    // MARK: - Detection

    @Test("A commit asks the bundle and records the answer, which every offer after it reads")
    func commitProbeRecordsWhatOffersRead() async throws {
        let (instance, store) = makeInstance()
        store.holdElsewhere(instance.bundleURL)
        #expect(instance.activity.decide(.start(recovery: false), posture: .offer) == .admit)

        #expect(
            instance.activity.decide(.start(recovery: false), posture: .commit)
                == .refuse(.heldByAnotherCopy))
        #expect(instance.activity.heldByAnotherCopy)
        #expect(
            instance.activity.decide(.start(recovery: false), posture: .offer)
                == .refuse(.heldByAnotherCopy))

        store.releaseElsewhere(instance.bundleURL)

        // The offer reads the recorded answer until a commit asks again.
        #expect(
            instance.activity.decide(.start(recovery: false), posture: .offer)
                == .refuse(.heldByAnotherCopy))
        #expect(instance.activity.decide(.start(recovery: false), posture: .commit) == .admit)
        #expect(!instance.activity.heldByAnotherCopy)
        #expect(instance.activity.decide(.start(recovery: false), posture: .offer) == .admit)
        expectLockFollowsPhase(instance, store)
    }

    @Test("A verb refused because another copy holds the VM dims its control, and one that finds it free un-dims it")
    func verbRefusalDimsAndAFreeProbeUndims() async throws {
        let harness = makeCore()
        let instance = harness.library.registerFixture()
        let catalog = VMCapabilityCatalog(library: harness.library)
        #expect(catalog.isAvailable(.start, on: instance))
        harness.store.holdElsewhere(instance.bundleURL)

        let refusal = await #expect(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: false)
        }
        // The summary names the VM as the refusal left it: held.
        #expect(refusal == .heldByAnotherCopy(vm: harness.core.summary(instance)))
        #expect(instance.heldByAnotherCopy)

        #expect(catalog.isApplicable(.start, to: instance))
        #expect(!catalog.isAvailable(.start, on: instance))

        harness.store.releaseElsewhere(instance.bundleURL)
        try harness.core.require(.start, on: instance)

        #expect(!instance.activity.heldByAnotherCopy)
        #expect(catalog.isAvailable(.start, on: instance))
        expectLockFollowsPhase(instance, harness.store)
    }

    // MARK: - Failures while taking the lock

    @Test("A bundle read that fails after the lock is taken lets the lock go and throws the read's failure")
    func failedReReadReleasesTheLock() async throws {
        let (instance, store) = makeInstance()
        store.setUnreadable(true, relativePath: VMBundleLayout.configRelativePath, at: instance.bundleURL)
        let recorder = Recorder()

        await #expect(throws: UnreadableBundleFile.self) {
            try await instance.activity.perform(.deletingSnapshot) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        }

        #expect(!recorder.bodyRan)
        #expect(instance.phase == .stopped)
        #expect(!instance.activity.heldByAnotherCopy)
        expectLockFollowsPhase(instance, store)

        store.setUnreadable(false, relativePath: VMBundleLayout.configRelativePath, at: instance.bundleURL)
        try await instance.activity.perform(.deletingSnapshot) { _ in .rest(.asStarted, ()) }
        expectLockFollowsPhase(instance, store)
    }

    @Test("A lock attempt that throws propagates its failure and commits nothing")
    func throwingLockAttemptPropagates() async throws {
        let (instance, store) = makeInstance()
        store.setLockError(Errno.noSuchFileOrDirectory, at: instance.bundleURL)
        let recorder = Recorder()

        await #expect(throws: Errno.noSuchFileOrDirectory) {
            try await instance.activity.perform(.creatingStorageDisk) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }
        }

        #expect(!recorder.bodyRan)
        #expect(instance.phase == .stopped)
        #expect(!instance.activity.heldByAnotherCopy)
        expectLockFollowsPhase(instance, store)
    }

    @Test("A VM another copy holds keeps its controls, dimmed")
    func catalogDimsAVMHeldElsewhere() async throws {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = library.registerFixture()
        storage.files.holdElsewhere(instance.bundleURL)
        await #expect(throws: VMAdmissionRefusal(refusal: .heldByAnotherCopy)) {
            try await instance.activity.perform(.deletingSnapshot) { _ in .rest(.asStarted, ()) }
        }

        let catalog = VMCapabilityCatalog(library: library)
        #expect(catalog.isApplicable(.start, to: instance))
        #expect(!catalog.isAvailable(.start, on: instance))
    }

    // MARK: - Verbs

    private struct CoreHarness {
        let core: VMCommandCore
        let library: VMLibrary
        let store: InMemoryVMBundleFiles
        let virtualization: MockVirtualizationService
    }

    private func makeCore() -> CoreHarness {
        let storage = MockVMStorageService()
        let store = storage.files
        let virtualization = MockVirtualizationService()
        let fileSystem = MockFileSystem()
        let lifecycle = makeTestLifecycle(virtualization: virtualization, fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, lifecycle: lifecycle, fileSystem: fileSystem)
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem,
            preferences: makeTestPreferences())
        return CoreHarness(core: core, library: library, store: store, virtualization: virtualization)
    }

    @Test("Start on a VM another copy holds is refused with the other copy named, and asks nothing of VZ")
    func startVerbIsRefusedWhileHeldElsewhere() async throws {
        let harness = makeCore()
        let instance = harness.library.registerFixture(name: "Held")
        harness.store.holdElsewhere(instance.bundleURL)

        do {
            try await harness.core.start(.id(instance.id), recovery: false)
            Issue.record("The start was not refused")
        } catch let refusal as CommandError {
            guard case .heldByAnotherCopy(let vm) = refusal else {
                Issue.record("Refused as \(refusal)")
                return
            }
            #expect(vm.id == instance.id)
            #expect(refusal.message == "\u{201C}Held\u{201D} is in use by another copy of Kernova.")
        }
        #expect(harness.virtualization.startCallCount == 0)
        #expect(instance.phase == .stopped)
        #expect(instance.activity.heldByAnotherCopy)
        expectLockFollowsPhase(instance, harness.store)
    }

    @Test("Start on a VM another copy left suspended restores its saved state")
    func startVerbRestoresASaveFileAnotherCopyLeft() async throws {
        let harness = makeCore()
        let instance = harness.library.registerFixture()
        try VMInstanceFixture.writeSaveFile(for: instance)

        try await harness.core.start(.id(instance.id), recovery: false)

        #expect(harness.virtualization.lastStartRoute == .restoredSavedState)
        expectLockFollowsPhase(instance, harness.store)
    }

    // MARK: - Launch sweep

    @Test("The launch sweep of revert staging skips a bundle another copy holds")
    func stagingSweepSkipsABundleHeldElsewhere() {
        let files = InMemoryVMBundleFiles()
        let store = MockVMBundleMachineFiles(files: files)
        let held = VMInstanceFixture.bundleURL(for: UUID())
        let free = VMInstanceFixture.bundleURL(for: UUID())
        files.holdElsewhere(held)

        VMBundle.Factory(machineFiles: store).reclaimRestoreStaging(
            in: [held, free].map { VMBundleFiles(url: $0, access: files) })

        #expect(store.sweptStagingBundleURLs == [free])
        #expect(files.bundlesLockedByThisCopy.isEmpty)
    }

    // MARK: - Real directories

    @Test("The real lock rides the bundle directory across a rename, and a probe sees it until it is dropped")
    func realLockRidesTheDirectory() throws {
        let parent = TestScratchDirectory(prefix: "VMRunLockTests").url
        let bundle = parent.appendingPathComponent("V.kernova", isDirectory: true)
        let moved = parent.appendingPathComponent("Moved.kernova", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let worker = CoordinatedBundleFileAccess()

        #expect(try worker.isBundleLockedElsewhere(at: bundle) == false)
        do {
            let holder = try #require(try worker.lockBundle(at: bundle))
            #expect(try worker.isBundleLockedElsewhere(at: bundle))
            #expect(try worker.lockBundle(at: bundle) == nil)
            try FileManager.default.moveItem(at: bundle, to: moved)
            #expect(try worker.isBundleLockedElsewhere(at: moved))
            #expect(try worker.lockBundle(at: moved) == nil)
            withExtendedLifetime(holder) {}
        }
        #expect(try worker.isBundleLockedElsewhere(at: moved) == false)
        #expect(try worker.lockBundle(at: moved) != nil)
    }
}
