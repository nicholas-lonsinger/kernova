import Foundation
import Testing

@testable import Kernova

/// The one place per-VM command capability is derived: what each state admits,
/// what a transient blocker takes away, and the one capability whose commit is
/// deliberately wider than its offer.
@Suite("VMCapabilityCatalog Tests", .serialized, .admissionGated)
@MainActor
struct VMCapabilityCatalogTests {
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.capabilities")

    private struct Harness {
        let catalog: VMCapabilityCatalog
        let library: VMLibrary
        let lifecycle: VMLifecycleCoordinator
        let storage: MockVMStorageService
    }

    private func makeHarness(
        virtualization: any VirtualizationProviding = MockVirtualizationService()
    ) -> Harness {
        let storage = MockVMStorageService()
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            linuxImageResolveService: MockLinuxImageResolveService(),
            downloadService: MockDownloadService(),
            fileSystem: MockFileSystem()
        )
        let library = VMLibrary(
            storageService: storage,
            snapshotStore: MockVMSnapshotStore(),
            lifecycle: lifecycle,
            fileSystem: MockFileSystem(),
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(),
            isVMNetworkingEntitled: true
        )
        return Harness(
            catalog: VMCapabilityCatalog(library: library), library: library, lifecycle: lifecycle,
            storage: storage)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Catalog VM", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux, snapshots: [VMSnapshot] = []
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots,
            library: harness.library, storage: harness.storage, preferences: preferences)
    }

    /// Applicable in every state, so each case below names only what its state
    /// adds.
    private static let universal: Set<VMCapability> = [
        .info, .ipAddress, .snapshots, .reveal, .showInFinder, .deleteSnapshot, .renameSnapshot,
        .setSnapshotNotes,
    ]

    // MARK: - Applicability by state

    @Test("Each phase admits exactly the capabilities its own predicates allow")
    func applicabilityByPhase() {
        let id = VMLifecyclePhaseFixtures.session
        let display: Set<VMCapability> = [.open, .toggleSettingsPane]
        let cases: [(label: String, phase: VMLifecyclePhase, added: Set<VMCapability>)] = [
            (
                "stopped", .stopped,
                [
                    .start, .takeSnapshot, .editStorageDisks, .editRemovableMedia,
                    .editSharedDirectories, .clone, .rename, .delete,
                ]
            ),
            (
                "running", .running(sessionID: id),
                [
                    .stop, .restart, .forceStop, .pause, .suspend, .open, .takeSnapshot,
                    .editRemovableMedia, .rename, .togglePopOut, .toggleFullscreen,
                    .toggleSettingsPane,
                ]
            ),
            (
                "live-paused", .livePaused(sessionID: id),
                [
                    .stop, .restart, .forceStop, .resume, .suspend, .open, .takeSnapshot,
                    .editRemovableMedia, .rename, .togglePopOut, .toggleFullscreen,
                    .toggleSettingsPane,
                ]
            ),
            // No save file on disk, so a suspended VM has no suspend slot to
            // capture.
            (
                "suspended", .suspended,
                [.discardSavedState, .resume, .open, .rename, .delete, .toggleSettingsPane]
            ),
            ("starting, no VM yet", .starting(sessionID: nil), []),
            ("starting", .starting(sessionID: id), [.forceStop]),
            ("saving", .saving(sessionID: id), display.union([.forceStop])),
            ("capturing live", .capturingLive(sessionID: id), display.union([.forceStop])),
            ("capturing at rest", .capturingAtRest, display),
            (
                "restoring a saved state", .restoringSavedState(sessionID: id),
                display.union([.forceStop])
            ),
            ("restoring, no VM yet", .restoringSavedState(sessionID: nil), display),
            ("reverting to a snapshot", .revertingToSnapshot, display),
            ("installing", .installing(sessionID: id), []),
            ("installing, no VM yet", .installing(sessionID: nil), []),
            (
                "failed", .failed(message: "Boot failed."),
                [
                    .start, .editStorageDisks, .editRemovableMedia, .editSharedDirectories, .clone,
                    .rename, .delete,
                ]
            ),
            (
                "initialBoot", .initialBoot,
                [
                    .start, .editStorageDisks, .editRemovableMedia, .editSharedDirectories, .clone,
                    .rename, .delete,
                ]
            ),
        ]

        for testCase in cases {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: testCase.phase)
            let applicable = Set(
                VMCapability.allCases.filter { harness.catalog.isApplicable($0, to: instance) })

            #expect(applicable == Self.universal.union(testCase.added), "\(testCase.label)")
        }

        // `VMLifecyclePhase` is `Equatable` but not `Hashable`, so completeness
        // is containment plus a count check rather than a `Set` comparison —
        // containment alone would still pass if a phase were dropped from the
        // fixture list, since a shorter list asks fewer questions.
        #expect(cases.count == VMLifecyclePhaseFixtures.all.count)
        for phase in VMLifecyclePhaseFixtures.all {
            #expect(cases.contains { $0.phase == phase }, "\(phase)")
        }
    }

    @Test("Nothing is available that is not applicable")
    func availabilityImpliesApplicability() {
        for phase in VMLifecyclePhaseFixtures.all {
            for snapshots: [VMSnapshot] in [[], [VMSnapshot(name: "Clean install")]] {
                let harness = makeHarness()
                let instance = makeInstance(in: harness, phase: phase, snapshots: snapshots)
                for capability in VMCapability.allCases
                where harness.catalog.isAvailable(capability, on: instance) {
                    #expect(
                        harness.catalog.isApplicable(capability, to: instance),
                        "\(capability) on \(phase), snapshots: \(snapshots.count)")
                }
            }
        }
    }

    @Test("A revert is applicable exactly when a snapshot exists to revert to and the VM is settled")
    func revertToSnapshotApplicability() {
        for phase in VMLifecyclePhaseFixtures.all {
            let stockedHarness = makeHarness()
            let stocked = makeInstance(
                in: stockedHarness, phase: phase, snapshots: [VMSnapshot(name: "Clean install")])
            #expect(
                stockedHarness.catalog.isApplicable(.revertToSnapshot, to: stocked)
                    == !phase.isTransitioning, "\(phase)")

            let emptyHarness = makeHarness()
            let empty = makeInstance(in: emptyHarness, phase: phase)
            #expect(!emptyHarness.catalog.isApplicable(.revertToSnapshot, to: empty), "\(phase)")
        }
    }

    // MARK: - Preparing

    @Test("A bundle still being copied offers only its reads, its reveal and its cancel")
    func preparingLeavesOnlyTheReadsAndItsCancel() {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()),
            snapshots: [VMSnapshot(name: "Clean install")])
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning(sourceID: UUID()), task: task)

        let available = Set(
            VMCapability.allCases.filter { harness.catalog.isAvailable($0, on: instance) })

        // Show in Finder is absent: the row's bundle URL holds nothing until the
        // write is published, so Finder would open on an empty directory.
        #expect(available == [.info, .ipAddress, .snapshots, .reveal, .cancelPreparing])
        // A snapshot exists and the phase is settled, so only `isPreparing`
        // keeps Revert to Snapshot from applying to a bundle still copying.
        #expect(!harness.catalog.isApplicable(.revertToSnapshot, to: instance))
    }

    @Test("Clone stays available while a different VM is being copied")
    func cloneIgnoresAnotherVMsCopy() {
        let harness = makeHarness()
        let settled = makeInstance(in: harness, name: "Settled")
        let copying = makeInstance(in: harness, name: "Copying")
        let task = Task {}
        defer { task.cancel() }
        copying.preparingState = VMInstance.PreparingState(operation: .cloning(sourceID: UUID()), task: task)

        // Bundle destinations are reserved atomically and overlapping copies are
        // a supported case, so one VM's copy says nothing about another's.
        #expect(harness.library.hasPreparing)
        #expect(harness.catalog.isAvailable(.clone, on: settled))
        #expect(!harness.catalog.isAvailable(.clone, on: copying))
    }

    @Test("A VM whose clone is still copying locks start, storage disks, delete and revert, and nothing else")
    func cloneInFlightLocksSourceButNothingElse() {
        let harness = makeHarness()
        let source = makeInstance(
            in: harness, name: "Source", snapshots: [VMSnapshot(name: "Clean install")])
        let other = makeInstance(in: harness, name: "Other")
        let phantom = makeInstance(in: harness, name: "Source Copy")
        let task = Task {}
        defer { task.cancel() }

        let locked: Set<VMCapability> = [.editStorageDisks, .delete, .revertToSnapshot, .start]
        let unaffected: Set<VMCapability> = [
            .clone, .rename, .editRemovableMedia, .editSharedDirectories,
        ]

        phantom.preparingState = VMInstance.PreparingState(
            operation: .cloning(sourceID: source.id), task: task)
        for capability in locked {
            #expect(!harness.catalog.isAvailable(capability, on: source), "\(capability)")
        }
        for capability in unaffected {
            #expect(harness.catalog.isAvailable(capability, on: source), "\(capability)")
        }

        // A clone of a different VM says nothing about this one.
        phantom.preparingState = VMInstance.PreparingState(
            operation: .cloning(sourceID: other.id), task: task)
        for capability in locked {
            #expect(harness.catalog.isAvailable(capability, on: source), "\(capability)")
        }

        // A cancelled clone still holds the lock until its uninterruptible copy settles.
        phantom.preparingState = VMInstance.PreparingState(
            operation: .cloning(sourceID: source.id), task: task, isCancelling: true)
        for capability in locked {
            #expect(!harness.catalog.isAvailable(capability, on: source), "\(capability)")
        }

        // The copy finished (or failed) and the phantom row is gone.
        phantom.preparingState = nil
        for capability in locked {
            #expect(harness.catalog.isAvailable(capability, on: source), "\(capability)")
        }
    }

    // MARK: - Settling

    @Test("Take Snapshot stays applicable but goes unavailable while an operation settles")
    func takeSnapshotWaitsForTheOperationToSettle() async throws {
        let suspending = SuspendingMockVirtualizationService()
        suspending.shouldSuspendOnResume = true
        let harness = makeHarness(virtualization: suspending)
        let instance = makeInstance(
            in: harness, phase: .livePaused(sessionID: UUID()),
            snapshots: [VMSnapshot(name: "Clean install")])

        #expect(harness.catalog.isAvailable(.takeSnapshot, on: instance))
        #expect(harness.catalog.isAvailable(.revertToSnapshot, on: instance))

        let resume = Task { @MainActor in try await harness.lifecycle.resume(instance) }
        await suspending.waitUntilSuspended()

        #expect(harness.catalog.isApplicable(.takeSnapshot, to: instance))
        #expect(!harness.catalog.isAvailable(.takeSnapshot, on: instance))
        #expect(!harness.catalog.isAvailable(.revertToSnapshot, on: instance))
        #expect(!harness.catalog.isAvailable(.deleteSnapshot, on: instance))
        // The lifecycle verbs carry no settle term — a stop has to be able to
        // interrupt an operation that is still running.
        #expect(harness.catalog.isAvailable(.stop, on: instance))
        // Nor do a snapshot's name and note: `VMCommandCore` writes both while
        // the VM is busy, so refusing them here would make `accepts` disagree
        // with the verb whose guard it is meant to be.
        #expect(harness.catalog.accepts(.renameSnapshot, on: instance))
        #expect(harness.catalog.accepts(.setSnapshotNotes, on: instance))

        suspending.resumeSuspended()
        try await resume.value
    }

    @Test("Only the three snapshot capabilities wait for an operation to settle")
    func settleTermCoversOnlyTheSnapshotCapabilities() {
        let waiting = VMCapability.allCases.filter(\.waitsForSettle)
        #expect(Set(waiting) == Set([.takeSnapshot, .revertToSnapshot, .deleteSnapshot]))
    }

    // MARK: - Rename: offer versus accept

    @Test("A rename typed while the VM began a transient is offered no longer but still taken")
    func renameAcceptsWiderThanItOffers() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .saving(sessionID: UUID()))

        #expect(!harness.catalog.isApplicable(.rename, to: instance))
        #expect(!harness.catalog.isAvailable(.rename, on: instance))
        #expect(harness.catalog.accepts(.rename, on: instance))
    }

    @Test("A revert refuses the rename it would assign back over")
    func renameRefusedDuringARevert() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .revertingToSnapshot)

        #expect(!harness.catalog.accepts(.rename, on: instance))
    }

    @Test("A bundle still being copied takes no rename either")
    func renameRefusedWhilePreparing() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .importing, task: task)

        #expect(!harness.catalog.accepts(.rename, on: instance))
    }

    @Test("Every capability but rename accepts exactly what it makes available")
    func acceptanceMatchesAvailabilityElsewhere() {
        for phase in VMLifecyclePhaseFixtures.all {
            for snapshots: [VMSnapshot] in [[], [VMSnapshot(name: "Clean install")]] {
                let harness = makeHarness()
                let instance = makeInstance(in: harness, phase: phase, snapshots: snapshots)
                for capability in VMCapability.allCases where capability != .rename {
                    #expect(
                        harness.catalog.accepts(capability, on: instance)
                            == harness.catalog.isAvailable(capability, on: instance),
                        "\(capability) on \(phase), snapshots: \(snapshots.count)")
                }
            }
        }
    }

    // MARK: - Guest-specific capabilities

    @Test("Recovery and the guest-agent disk are macOS-guest capabilities")
    func macOSOnlyCapabilities() {
        let harness = makeHarness()
        let linux = makeInstance(in: harness, name: "Linux", phase: .stopped)
        let mac = makeInstance(in: harness, name: "macOS", phase: .stopped, guestOS: .macOS)

        #expect(!harness.catalog.isApplicable(.startInRecovery, to: linux))
        #expect(harness.catalog.isApplicable(.startInRecovery, to: mac))

        // The agent disk additionally needs a live session to look inside, which
        // neither stopped VM has.
        #expect(!harness.catalog.isApplicable(.toggleGuestAgentDisk, to: mac))
        let running = makeInstance(
            in: harness, name: "Running macOS", phase: .running(sessionID: UUID()),
            guestOS: .macOS)
        #expect(harness.catalog.isApplicable(.toggleGuestAgentDisk, to: running))
    }

    @Test("An Ephemeral baseline is undeletable, and every other snapshot is not")
    func canDeleteSnapshotProtectsTheEphemeralBaseline() {
        let harness = makeHarness()
        let baseline = VMSnapshot(name: "Clean install")
        let later = VMSnapshot(name: "Configured")
        let instance = makeInstance(in: harness, snapshots: [baseline, later])
        instance.configuration.applyEphemeralMode(enabled: true, baseline: baseline.id)

        #expect(!harness.catalog.canDeleteSnapshot(baseline, on: instance))
        #expect(harness.catalog.canDeleteSnapshot(later, on: instance))

        // Turning the mode off releases the baseline: nothing needs it back.
        instance.configuration.applyEphemeralMode(enabled: false, baseline: nil)
        #expect(harness.catalog.canDeleteSnapshot(baseline, on: instance))
    }

    @Test("No snapshot is deletable in a state the manifest cannot be edited in")
    func canDeleteSnapshotFollowsTheCapability() {
        let harness = makeHarness()
        let snapshot = VMSnapshot(name: "Configured")
        let instance = makeInstance(
            in: harness, phase: .revertingToSnapshot, snapshots: [snapshot])

        #expect(!harness.catalog.isAvailable(.deleteSnapshot, on: instance))
        #expect(!harness.catalog.canDeleteSnapshot(snapshot, on: instance))
    }

    @Test("The clipboard window follows the VM's own sharing toggle")
    func clipboardFollowsTheSharingToggle() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        #expect(!harness.catalog.isApplicable(.showClipboard, to: instance))

        instance.configuration.clipboardSharingEnabled = true
        #expect(harness.catalog.isApplicable(.showClipboard, to: instance))
    }
}
