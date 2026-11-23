import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import System
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

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
            try await context.bringUp.operation.executingGuest { _ in
                context.bringUp.bindSessionForTesting(UUID())
            }
            return .rest(.live(.running), ())
        }.resolved()
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
            }.resolved()
        },
        Attempt(description: "restore", phase: .suspended, slot: true) { instance, recorder in
            try await instance.activity.launchStartGuest(.restoringSavedState) { _ in
                recorder.bodyRan = true
                return .rest(.asStarted, ())
            }.resolved()
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
            try await instance.activity.launchedCapture(.stopped) { _ in
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
            try instance.activity.launch(.copyingOut(.stopped)) { _ in
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
        }.resolved()
        #expect(recorder.heldInBody == true)
        expectLockFollowsPhase(instance, store)

        // Live operations keep it.
        try await instance.activity.perform(.pausing) { _ in .rest(.live(.paused), ()) }
        expectLockFollowsPhase(instance, store)
        try await instance.activity.perform(.resuming) { _ in .rest(.live(.running), ()) }
        expectLockFollowsPhase(instance, store)

        // A session ending rests the VM and lets it go.
        let sessionID = try #require(instance.liveSessionID)
        instance.activity.deliverSessionEvent(.guestDidStop, from: sessionID)
        #expect(instance.phase == .stopped)
        expectLockFollowsPhase(instance, store)

        // A Force Stop's ending.
        try await startLive(instance)
        let stopped = try #require(instance.liveSessionID)
        let stop = try instance.activity.forceStop {}
        instance.activity.deliverSessionEvent(.stopDidComplete, from: stopped)
        try await stop.resolved()
        #expect(instance.phase == .stopped)
        expectLockFollowsPhase(instance, store)

        // A suspend that ends at rest.
        try await startLive(instance)
        try await instance.activity.perform(.saving) { _ in .rest(.atRest(.stopped), ()) }
        expectLockFollowsPhase(instance, store)

        // A re-read that fails after the lock is taken lets it go.
        let config = VMBundleLayout.configRelativePath
        store.setUnreadable(true, relativePath: config, at: instance.bundleURL)
        await #expect(throws: UnreadableConfigFile.self) {
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
            }.resolved()
        }
        expectLockFollowsPhase(instance, store)

        // A launched operation, held across its whole body.
        let gate = GatedStep()
        let outcome = try instance.activity.launch(.copyingOut(.stopped)) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
        try await gate.waitUntilEntered()
        expectLockFollowsPhase(instance, store)
        gate.release()
        try await outcome.resolved()
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
        }.resolved()

        #expect(recorder.startedFrom == .stopped)
        #expect(recorder.pendingSetupInBody == false)
        #expect(instance.phase == .stopped)
        expectLockFollowsPhase(instance, store)
    }

    // MARK: - Launch sweep

    @Test("The launch sweep of revert staging and spent suspend slots skips a bundle another copy holds")
    func stagingSweepSkipsABundleHeldElsewhere() throws {
        let files = InMemoryVMBundleFiles()
        let store = MockVMBundleMachineFiles(files: files)
        let held = VMInstanceFixture.bundleURL(for: UUID())
        let free = VMInstanceFixture.bundleURL(for: UUID())
        files.holdElsewhere(held)
        for bundleURL in [held, free] {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try Data("spent".utf8).write(to: VMBundleLayout(bundleURL: bundleURL).spentSaveFileURL)
        }

        VMBundle.Factory(machineFiles: store).reclaimInterruptedWork(
            in: [held, free].map { VMBundleFiles(url: $0, access: files) })

        #expect(store.sweptStagingBundleURLs == [free])
        #expect(files.bundlesLockedByThisCopy.isEmpty)
        func holdsSpentSlot(_ bundleURL: URL) -> Bool {
            FileManager.default.fileExists(
                atPath: VMBundleLayout(bundleURL: bundleURL).spentSaveFileURL.path(percentEncoded: false))
        }
        #expect(!holdsSpentSlot(free))
        #expect(holdsSpentSlot(held))
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
