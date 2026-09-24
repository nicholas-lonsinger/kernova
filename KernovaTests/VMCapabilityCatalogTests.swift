import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// The one place per-VM command capability is derived: what each state admits,
/// what a transient blocker takes away, and the capabilities whose commit is
/// wider than their offer.
@Suite("VMCapabilityCatalog Tests", .serialized, .admissionGated)
@MainActor
struct VMCapabilityCatalogTests {
    private let preferences = makeTestPreferences()

    private struct Harness {
        let catalog: VMCapabilityCatalog
        let library: VMLibrary
        let lifecycle: VMLifecycleCoordinator
        let storage: MockVMStorageService
    }

    private func makeHarness(
        virtualization: any VirtualizationProviding = MockVirtualizationService(),
        usbAccessories: (any USBAccessoryProviding)? = nil
    ) -> Harness {
        let storage = MockVMStorageService()
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization,
            usbAccessoryService: usbAccessories)
        let library = makeWiredLibrary(
            storage: storage,
            lifecycle: lifecycle,
            preferences: preferences)
        return Harness(
            catalog: VMCapabilityCatalog(library: library), library: library, lifecycle: lifecycle,
            storage: storage)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Catalog VM", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux, snapshots: [VMSnapshot] = [],
        hostState: VMHostState = VMHostState(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots,
            library: harness.library, storage: harness.storage, preferences: preferences,
            hostState: hostState, mutate: mutate)
    }

    /// Applicable in every state, so each case below names only what its state
    /// adds.
    private static let universal: Set<VMCapability> = [
        .info, .ipAddress, .snapshots, .reveal, .showInFinder, .deleteSnapshot, .renameSnapshot,
        .setSnapshotNotes, .editLiveConfiguration,
    ]

    /// The configuration edits every at-rest phase adds, named once — the
    /// settings whose values are pinned by a live session or a saved state.
    private static let atRestConfiguration: Set<VMCapability> = [
        .editConfiguration, .switchNetworkMode,
    ]

    // MARK: - Applicability by state

    @Test("Each phase admits exactly the capabilities its own predicates allow")
    func applicabilityByPhase() {
        let id = VMLifecyclePhaseFixtures.session
        let display: Set<VMCapability> = [.open, .toggleSettingsPane]
        let cases: [(label: String, phase: VMLifecyclePhase, added: Set<VMCapability>)] = [
            (
                "stopped", .stopped,
                Self.atRestConfiguration.union([
                    .start, .takeSnapshot, .editStorageDisks, .editRemovableMedia,
                    .editSharedDirectories, .clone, .rename, .delete,
                ])
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
            // No save file on disk, so this VM holds no suspended session:
            // Resume, Discard and the suspend-slot capture all fall away, and
            // what is left is an at-rest VM whose settings nothing pins.
            (
                "suspended, slot gone", .suspended,
                Self.atRestConfiguration.union([
                    .start, .editStorageDisks, .editRemovableMedia, .editSharedDirectories,
                    .clone, .rename, .delete, .open, .toggleSettingsPane,
                ])
            ),
            // No phase between a bring-up and a settled guest offers a force
            // stop: VZ takes a termination only from Running or Paused, so the
            // offer would be a control the framework refuses.
            ("starting, no VM yet", .starting(sessionID: nil), []),
            ("starting", .starting(sessionID: id), []),
            ("saving", .saving(sessionID: id), display),
            ("capturing live", .capturingLive(sessionID: id), display),
            ("capturing at rest", .capturingAtRest, display),
            ("restoring a saved state", .restoringSavedState(sessionID: id), display),
            ("restoring, no VM yet", .restoringSavedState(sessionID: nil), display),
            ("reverting to a snapshot", .revertingToSnapshot, display),
            ("installing", .installing(sessionID: id), []),
            ("installing, no VM yet", .installing(sessionID: nil), []),
            (
                "failed", .failed(message: "Boot failed."),
                Self.atRestConfiguration.union([
                    .start, .editStorageDisks, .editRemovableMedia, .editSharedDirectories, .clone,
                    .rename, .delete,
                ])
            ),
            (
                "initialBoot", .initialBoot,
                Self.atRestConfiguration.union([
                    .start, .editStorageDisks, .editRemovableMedia, .editSharedDirectories, .clone,
                    .rename, .delete,
                ])
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

    /// Everything a saved state pins, because VZ restores one only into the
    /// configuration it was written under.
    private static let pinnedBySavedState: Set<VMCapability> = [
        .editStorageDisks, .editRemovableMedia, .editSharedDirectories,
        .editConfiguration, .switchNetworkMode, .clone,
    ]

    @Test("A saved state pins an at-rest VM's settings and trades its Start for Resume")
    func aSavedStateRepinsWhatAnAtRestVMOffers() throws {
        for phase: VMLifecyclePhase in [.stopped, .failed(message: "Boot failed."), .suspended] {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)
            defer { VMInstanceFixture.removeBundle(of: instance) }

            // With no slot on disk, every at-rest phase answers the same way.
            #expect(harness.catalog.isApplicable(.start, to: instance), "\(phase)")
            #expect(!harness.catalog.isApplicable(.resume, to: instance), "\(phase)")
            #expect(!harness.catalog.isApplicable(.discardSavedState, to: instance), "\(phase)")
            for capability in Self.pinnedBySavedState {
                #expect(
                    harness.catalog.isApplicable(capability, to: instance),
                    "\(capability) with no slot, \(phase)")
            }
            #expect(harness.catalog.isApplicable(.delete, to: instance), "\(phase)")
            #expect(harness.catalog.bringUpVerb(for: instance) == .start, "\(phase)")

            try VMInstanceFixture.writeSaveFile(for: instance)

            for capability in Self.pinnedBySavedState {
                #expect(
                    !harness.catalog.isApplicable(capability, to: instance),
                    "\(capability) with a slot, \(phase)")
            }
            #expect(!harness.catalog.isApplicable(.start, to: instance), "\(phase)")
            #expect(harness.catalog.isApplicable(.resume, to: instance), "\(phase)")
            #expect(harness.catalog.isApplicable(.discardSavedState, to: instance), "\(phase)")
            // Delete keeps working: the slot is a file inside the bundle and
            // goes with it.
            #expect(harness.catalog.isApplicable(.delete, to: instance), "\(phase)")
            // The offer names Resume; a start committed anyway restores rather
            // than being refused.
            #expect(harness.catalog.bringUpVerb(for: instance) == .resume, "\(phase)")
            #expect(harness.catalog.accepts(.start, on: instance), "\(phase)")
            #expect(harness.catalog.stopAction(for: instance) == .discardSavedState, "\(phase)")
        }
    }

    @Test("Nothing is available that is not applicable")
    func availabilityImpliesApplicability() {
        for phase in VMLifecyclePhaseFixtures.all {
            for snapshots: [VMSnapshot] in [[], [VMSnapshot(name: "Clean install", macAddress: nil)]] {
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
                in: stockedHarness, phase: phase, snapshots: [VMSnapshot(name: "Clean install", macAddress: nil)])
            #expect(
                stockedHarness.catalog.isApplicable(.revertToSnapshot, to: stocked)
                    == !phase.isTransitioning, "\(phase)")

            let emptyHarness = makeHarness()
            let empty = makeInstance(in: emptyHarness, phase: phase)
            #expect(!emptyHarness.catalog.isApplicable(.revertToSnapshot, to: empty), "\(phase)")
        }
    }

    // MARK: - The stop slot

    @Test("The stop slot names a graceful stop, a discard, or an Ephemeral revert")
    func stopActionNamesWhatTheSlotDoes() throws {
        let harness = makeHarness()
        let running = makeInstance(in: harness, name: "Running", phase: .running(sessionID: UUID()))
        #expect(harness.catalog.stopAction(for: running) == .stop)

        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        defer { VMInstanceFixture.removeBundle(of: suspended) }
        try VMInstanceFixture.writeSaveFile(for: suspended)
        #expect(harness.catalog.stopAction(for: suspended) == .discardSavedState)

        let baseline = VMSnapshot(name: "Ephemeral", macAddress: nil)
        let ephemeral = makeInstance(
            in: harness, name: "Ephemeral VM", phase: .suspended, snapshots: [baseline],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id))
        defer { VMInstanceFixture.removeBundle(of: ephemeral) }
        try VMInstanceFixture.writeSaveFile(for: ephemeral)
        #expect(harness.catalog.stopAction(for: ephemeral) == .revertToBaseline)
    }

    @Test("The stop slot stands for both capabilities that can fill it")
    func stopActionAvailabilityCoversBothCapabilities() throws {
        let harness = makeHarness()
        let running = makeInstance(in: harness, name: "Running", phase: .running(sessionID: UUID()))
        #expect(harness.catalog.isAvailable(.stop, on: running))
        #expect(harness.catalog.isStopActionAvailable(on: running))

        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        defer { VMInstanceFixture.removeBundle(of: suspended) }
        try VMInstanceFixture.writeSaveFile(for: suspended)
        #expect(!harness.catalog.isAvailable(.stop, on: suspended))
        #expect(harness.catalog.isAvailable(.discardSavedState, on: suspended))
        #expect(harness.catalog.isStopActionAvailable(on: suspended))

        let stopped = makeInstance(in: harness, name: "Stopped", phase: .stopped)
        #expect(!harness.catalog.isStopActionAvailable(on: stopped))
    }

    // MARK: - Preparing

    @Test("A bundle still being copied offers only its reads, its reveal and its cancel")
    func preparingLeavesOnlyTheReadsAndItsCancel() {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()),
            snapshots: [VMSnapshot(name: "Clean install", macAddress: nil)])
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
        // The settings read at moments other than boot apply in every state, so
        // `survivesPreparing` is the whole of what keeps a configuration write
        // off a bundle still being copied — and it is the level a verb guard
        // reads, which is why no verb needs a preparing check of its own.
        #expect(harness.catalog.isApplicable(.editLiveConfiguration, to: instance))
        #expect(!harness.catalog.accepts(.editLiveConfiguration, on: instance))
        #expect(!harness.catalog.accepts(.editConfiguration, on: instance))
        #expect(!harness.catalog.accepts(.switchNetworkMode, on: instance))
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
            in: harness, name: "Source", snapshots: [VMSnapshot(name: "Clean install", macAddress: nil)])
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
            snapshots: [VMSnapshot(name: "Clean install", macAddress: nil)])

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

    // MARK: - Bring-up: offer versus accept

    @Test("A start is taken in either bring-up phase, and offered in neither")
    func startAcceptsAVMAlreadyComingUp() {
        // What lets the CLI verb that cold-launched the app join the boot the
        // launch auto-start pass began, in whichever order the two resumed. The
        // restore phases carry it too: a boot with a save file spends its whole
        // observable window there, not in `.starting`.
        let bringingUp: [VMLifecyclePhase] = [
            .starting(sessionID: nil), .starting(sessionID: UUID()),
            .restoringSavedState(sessionID: nil), .restoringSavedState(sessionID: UUID()),
        ]
        for phase in bringingUp {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)

            #expect(harness.catalog.accepts(.start, on: instance), "\(phase)")
            #expect(!harness.catalog.isApplicable(.start, to: instance), "\(phase)")
            #expect(!harness.catalog.isAvailable(.start, on: instance), "\(phase)")
        }
    }

    @Test("The bring-up exceptions widen the state term only, not the transient blockers")
    func bringUpExceptionsStillHonorTheCloneLock() {
        // A start locks the source of a clone still copying files out of its
        // bundle, and joining one does not exempt it: the exception replaces
        // what the VM's own state admits, and nothing else.
        let harness = makeHarness()
        let source = makeInstance(in: harness, name: "Source", phase: .starting(sessionID: nil))
        let phantom = makeInstance(in: harness, name: "Source copy")
        let task = Task {}
        defer { task.cancel() }
        phantom.preparingState = VMInstance.PreparingState(
            operation: .cloning(sourceID: source.id), task: task)

        #expect(!harness.catalog.accepts(.start, on: source))

        phantom.preparingState = nil
        #expect(harness.catalog.accepts(.start, on: source))
    }

    @Test("A resume is taken against a VM already restoring, and offered on none")
    func resumeAcceptsAVMAlreadyRestoring() {
        for phase: VMLifecyclePhase in [
            .restoringSavedState(sessionID: nil), .restoringSavedState(sessionID: UUID()),
        ] {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)

            #expect(harness.catalog.accepts(.resume, on: instance), "\(phase)")
            #expect(!harness.catalog.isApplicable(.resume, to: instance), "\(phase)")
            #expect(!harness.catalog.isAvailable(.resume, on: instance), "\(phase)")
        }
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

    @Test("Outside the offer-versus-accept exceptions, a commit is exactly an offer")
    func acceptanceMatchesAvailabilityElsewhere() {
        /// The pairs the two levels disagree on: rename in every phase, and
        /// each bring-up verb in the phase it joins.
        func isAnException(_ capability: VMCapability, in phase: VMLifecyclePhase) -> Bool {
            switch (capability, phase) {
            case (.rename, _), (.start, .starting), (.start, .restoringSavedState),
                (.resume, .restoringSavedState):
                true
            default: false
            }
        }

        for phase in VMLifecyclePhaseFixtures.all {
            for snapshots: [VMSnapshot] in [[], [VMSnapshot(name: "Clean install", macAddress: nil)]] {
                let harness = makeHarness()
                let instance = makeInstance(in: harness, phase: phase, snapshots: snapshots)
                for capability in VMCapability.allCases where !isAnException(capability, in: phase) {
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
        let baseline = VMSnapshot(name: "Clean install", macAddress: nil)
        let later = VMSnapshot(name: "Configured", macAddress: nil)
        let instance = makeInstance(
            in: harness, snapshots: [baseline, later],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id))

        #expect(!harness.catalog.canDeleteSnapshot(baseline, on: instance))
        #expect(harness.catalog.canDeleteSnapshot(later, on: instance))

        // Turning the mode off releases the baseline: nothing needs it back.
        harness.library.editHostState(of: instance) {
            $0.applyEphemeralMode(enabled: false, baseline: nil)
        }
        #expect(harness.catalog.canDeleteSnapshot(baseline, on: instance))
    }

    @Test("No snapshot is deletable in a state the manifest cannot be edited in")
    func canDeleteSnapshotFollowsTheCapability() {
        let harness = makeHarness()
        let snapshot = VMSnapshot(name: "Configured", macAddress: nil)
        let instance = makeInstance(
            in: harness, phase: .revertingToSnapshot, snapshots: [snapshot])

        #expect(!harness.catalog.isAvailable(.deleteSnapshot, on: instance))
        #expect(!harness.catalog.canDeleteSnapshot(snapshot, on: instance))
    }

    /// A row renders its Delete's enablement and its explanation from this one
    /// answer, so the baseline's bar has to be distinguishable from every other
    /// reason the delete is off.
    @Test("The delete offer names the baseline bar apart from an unavailable manifest")
    func snapshotDeleteOfferNamesWhatBarsIt() {
        let harness = makeHarness()
        let baseline = VMSnapshot(name: "Clean install", macAddress: nil)
        let later = VMSnapshot(name: "Configured", macAddress: nil)
        let instance = makeInstance(
            in: harness, snapshots: [baseline, later],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id))

        #expect(harness.catalog.snapshotDeleteOffer(baseline, on: instance) == .barredAsBaseline)
        #expect(harness.catalog.snapshotDeleteOffer(later, on: instance) == .offered)

        // A state the manifest cannot be edited in takes both rows, and says so
        // as the state rather than as the mode.
        instance.enter(.revertingToSnapshot)
        #expect(harness.catalog.snapshotDeleteOffer(baseline, on: instance) == .unavailable)
        #expect(harness.catalog.snapshotDeleteOffer(later, on: instance) == .unavailable)
    }

    @Test("A USB accessory edit exists only in a build that can pass one through")
    func usbAccessoryEditFollowsTheCapability() {
        let without = makeHarness()
        let notOffered = makeInstance(in: without, phase: .running(sessionID: UUID()))
        // A build that cannot claim an accessory must not name the verb among
        // those a VM accepts, however the VM is running.
        #expect(!without.catalog.isApplicable(.editUSBAccessories, to: notOffered))

        let with = makeHarness(usbAccessories: MockUSBAccessoryService())
        #expect(
            with.catalog.isApplicable(
                .editUSBAccessories, to: makeInstance(in: with, phase: .running(sessionID: UUID()))))
        // Stricter than removable media: there is no persisted entry to
        // pre-configure, so a guest that is not running takes no edit.
        #expect(
            !with.catalog.isApplicable(
                .editUSBAccessories, to: makeInstance(in: with, name: "Resting", phase: .stopped)))
    }

    @Test("The clipboard window follows the VM's own sharing toggle")
    func clipboardFollowsTheSharingToggle() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        #expect(!harness.catalog.isApplicable(.showClipboard, to: instance))

        harness.library.editConfiguration(of: instance) { $0.clipboardSharingEnabled = true }
        #expect(harness.catalog.isApplicable(.showClipboard, to: instance))
    }

    // MARK: - Reveal surface

    /// Which window a `reveal` — from the CLI, a `kernova:` link, AppleScript,
    /// the Open intent, or a click in the status-item dropdown — brings forward.
    ///
    /// The gate is ``VMCapability/open``'s, so a phase with a display to show
    /// opens the window showing it whatever that display currently holds: the
    /// paused poster of a suspended VM and the transition label of a VM being
    /// captured, as much as the live guest of a running one.
    @Test("The reveal surface follows the display a VM has and where that display lives")
    func revealSurfaceByPreferenceAndPhase() {
        let live = VMLifecyclePhaseFixtures.session
        // Where a pop-out or fullscreen VM reveals to, per phase. An inline VM
        // reveals into the library in every one of them, which the loop asserts
        // alongside.
        let cases: [(phase: VMLifecyclePhase, detached: VMCapabilityCatalog.RevealSurface)] = [
            (.stopped, .library),
            (.initialBoot, .library),
            (.failed(message: "Boot failed."), .library),
            (.starting(sessionID: nil), .library),
            (.starting(sessionID: live), .library),
            (.installing(sessionID: nil), .library),
            (.installing(sessionID: live), .library),
            (.running(sessionID: live), .displayWindow),
            (.livePaused(sessionID: live), .displayWindow),
            (.suspended, .displayWindow),
            (.saving(sessionID: live), .displayWindow),
            (.capturingLive(sessionID: live), .displayWindow),
            (.capturingAtRest, .displayWindow),
            (.restoringSavedState(sessionID: nil), .displayWindow),
            (.restoringSavedState(sessionID: live), .displayWindow),
            (.revertingToSnapshot, .displayWindow),
        ]

        for (index, expected) in cases.enumerated() {
            let harness = makeHarness()
            for preference in [VMDisplayPreference.popOut, .fullscreen] {
                let instance = makeInstance(
                    in: harness, name: "VM \(index) \(preference)", phase: expected.phase,
                    hostState: VMHostState(displayPreference: preference))
                #expect(
                    harness.catalog.revealSurface(for: instance) == expected.detached,
                    "\(expected.phase) \(preference)")
            }
            let inline = makeInstance(
                in: harness, name: "VM \(index) inline", phase: expected.phase)
            #expect(
                harness.catalog.revealSurface(for: inline) == .library, "\(expected.phase) inline")
        }

        // Completeness by containment plus a count, for the reason
        // `applicabilityByPhase` states: `VMLifecyclePhase` is `Equatable` but
        // not `Hashable`.
        #expect(cases.count == VMLifecyclePhaseFixtures.all.count)
        for phase in VMLifecyclePhaseFixtures.all {
            #expect(cases.contains { $0.phase == phase }, "\(phase)")
        }
    }

    /// The phantom row of an import still copying rests `.paused` and reads as
    /// having a display, which is the one VM whose display window is not the
    /// right thing to open.
    @Test("A VM whose bundle is still being written reveals in the library")
    func revealSurfaceOfAPreparingVMIsTheLibrary() {
        let harness = makeHarness()
        let phantom = makeInstance(
            in: harness, phase: .suspended, hostState: VMHostState(displayPreference: .popOut))
        let task = Task {}
        defer { task.cancel() }

        #expect(harness.catalog.revealSurface(for: phantom) == .displayWindow)

        phantom.preparingState = VMInstance.PreparingState(operation: .importing, task: task)
        #expect(harness.catalog.revealSurface(for: phantom) == .library)
    }

    // MARK: - Bring-up

    @Test(
        "The bring-up verb boots a resting VM and restores one holding a saved state",
        arguments: [
            (VMLifecyclePhase.stopped, false, VMCapabilityCatalog.BringUpVerb.start),
            (.failed(message: "Boot failed."), false, .start),
            // A suspension whose slot has gone boots: there is nothing left to
            // restore, whatever the phase is still called.
            (.suspended, false, .start),
            (.stopped, true, .resume),
            (.failed(message: "Restore failed."), true, .resume),
            (.suspended, true, .resume),
        ] as [(VMLifecyclePhase, Bool, VMCapabilityCatalog.BringUpVerb)])
    func bringUpVerbByPhase(
        phase: VMLifecyclePhase, holdsSavedState: Bool,
        expected: VMCapabilityCatalog.BringUpVerb
    ) throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: phase)
        defer { VMInstanceFixture.removeBundle(of: instance) }
        if holdsSavedState { try VMInstanceFixture.writeSaveFile(for: instance) }

        #expect(harness.catalog.bringUpVerb(for: instance) == expected)
        // The standing pass adds guards on top of this one and changes nothing
        // else, so a VM with neither of them outstanding answers the same.
        #expect(harness.catalog.standingBringUp(for: instance) == expected)
    }

    @Test(
        "No phase that is already live, or on its way somewhere, has a bring-up owed",
        arguments: [
            VMLifecyclePhase.running(sessionID: VMLifecyclePhaseFixtures.session),
            // Live-paused: the VZ object is already in memory, so there is
            // nothing to bring up.
            .livePaused(sessionID: VMLifecyclePhaseFixtures.session),
            .starting(sessionID: VMLifecyclePhaseFixtures.session),
            .saving(sessionID: VMLifecyclePhaseFixtures.session),
            .revertingToSnapshot,
            .installing(sessionID: VMLifecyclePhaseFixtures.session),
        ])
    func bringUpVerbRefusesLivePhases(phase: VMLifecyclePhase) {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: phase)

        #expect(harness.catalog.bringUpVerb(for: instance) == nil)
        #expect(harness.catalog.standingBringUp(for: instance) == nil)
    }

    /// A start here runs the macOS install or the Linux image download, and
    /// neither may begin from a standing preference. The context decides, not
    /// the phase: a failed install keeps its context at `.failed`, where the
    /// phase alone reads as an ordinary boot retry.
    @Test(
        "A VM that has yet to finish guest setup takes no standing bring-up",
        arguments: [
            VMLifecyclePhase.initialBoot,
            .failed(message: "Install failed."),
            .stopped,
        ])
    func standingBringUpRefusesPendingSetup(phase: VMLifecyclePhase) {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: phase) {
            $0.installContext = MacOSInstallContext(source: .downloadLatest)
        }

        #expect(instance.configuration.pendingGuestSetup != nil)
        #expect(harness.catalog.standingBringUp(for: instance) == nil)
        // A commanded bring-up is not blocked by it: the verb runs the setup and
        // chains the boot.
        #expect(harness.catalog.bringUpVerb(for: instance) != nil)
    }

    @Test("A bundle still being copied has no bring-up to offer")
    func bringUpVerbRefusesPreparing() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .stopped)
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .importing, task: task)

        #expect(harness.catalog.bringUpVerb(for: instance) == nil)
        #expect(harness.catalog.standingBringUp(for: instance) == nil)
    }

    // MARK: - The guest account

    @available(macOS 27.0, *)
    @Test("The account state walks from nothing, through owed, to answered")
    func guestAccountStateWalksItsThreeStandings() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .stopped, guestOS: .macOS)
        let intent = GuestAccountIntent(
            fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
            enablesRemoteLogin: false)

        #expect(harness.catalog.guestAccountState(of: instance) == .none)

        harness.library.editConfiguration(of: instance) { $0.pendingGuestAccount = intent }
        #expect(harness.catalog.guestAccountState(of: instance) == .owed(intent))
        #expect(harness.catalog.owesGuestAccountAnswer(instance))

        harness.library.holdGuestAccountPassword(
            GuestAccountPassword("analytical-engine"), for: instance)
        #expect(
            harness.catalog.guestAccountState(of: instance)
                == .answered(intent, GuestAccountPassword("analytical-engine")))
        #expect(!harness.catalog.owesGuestAccountAnswer(instance))
    }

    /// The pass reads the same predicate the verb does, so a VM whose start
    /// would raise a question is passed over rather than alerted about at a
    /// login with no window to alert in.
    @available(macOS 27.0, *)
    @Test(
        "A VM still owing its guest an account answer takes no standing bring-up",
        arguments: [VMLifecyclePhase.stopped, .suspended, .failed(message: "Boot failed.")])
    func standingBringUpRefusesAnOwedAccount(phase: VMLifecyclePhase) {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: phase, guestOS: .macOS)
        // Answered first, to show the phase alone would have brought it up.
        #expect(harness.catalog.standingBringUp(for: instance) != nil)

        harness.library.editConfiguration(of: instance) {
            $0.pendingGuestAccount = GuestAccountIntent(
                fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
                enablesRemoteLogin: false)
        }

        #expect(harness.catalog.owesGuestAccountAnswer(instance))
        #expect(harness.catalog.standingBringUp(for: instance) == nil)
    }

    @available(macOS 27.0, *)
    @Test("A VM whose account answer is held owes nothing, and takes the standing bring-up")
    func standingBringUpAdmitsAnAnsweredAccount() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .stopped, guestOS: .macOS) {
            $0.pendingGuestAccount = GuestAccountIntent(
                fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
                enablesRemoteLogin: false)
        }
        #expect(harness.catalog.standingBringUp(for: instance) == nil)

        harness.library.holdGuestAccountPassword(
            GuestAccountPassword("analytical-engine"), for: instance)

        // The intent is still there — the boot has yet to spend it — but there is
        // no question left to raise, which is the whole of what the pass avoids.
        #expect(instance.configuration.pendingGuestAccount != nil)
        #expect(!harness.catalog.owesGuestAccountAnswer(instance))
        #expect(harness.catalog.standingBringUp(for: instance) == .start)
    }

    @available(macOS 27.0, *)
    @Test("A retraction leaves nothing owed and nothing held")
    func retractingEndsBothHalves() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .stopped, guestOS: .macOS) {
            $0.pendingGuestAccount = GuestAccountIntent(
                fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
                enablesRemoteLogin: false)
        }
        harness.library.holdGuestAccountPassword(
            GuestAccountPassword("analytical-engine"), for: instance)

        harness.library.retractGuestAccount(for: instance)

        // Not "asks again": the window is gone, so the question is gone with it.
        #expect(instance.configuration.pendingGuestAccount == nil)
        #expect(harness.library.heldGuestAccountPassword(for: instance) == nil)
        #expect(!harness.catalog.owesGuestAccountAnswer(instance))
    }

    @available(macOS 27.0, *)
    @Test("Retracting an account a VM never owed writes nothing")
    func retractingWithoutAnAccountWritesNothing() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .stopped, guestOS: .macOS)
        let writesBefore = harness.storage.saveConfigurationCallCount

        harness.library.retractGuestAccount(for: instance)

        #expect(harness.storage.saveConfigurationCallCount == writesBefore)
    }
}
