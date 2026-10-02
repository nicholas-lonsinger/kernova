import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// The catalog's own part of per-VM capability: which request each capability
/// asks admission for, how its three levels read that one decision, and the
/// surfaces derived from them. What admission decides for each request is
/// ``VMAdmissionTests``'.
@Suite("VMCapabilityCatalog Tests", .serialized, .caseScoped)
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
            library: harness.library, preferences: preferences,
            hostState: hostState, mutate: mutate)
    }

    private static let coldBoot = VMOperationKind.bringUp(.guestStart(.starting(recovery: false)))

    // MARK: - The request each capability asks for

    /// Written out independently of ``VMCapability/request(on:)``; the revert
    /// and the USB edit name a snapshot and an accessory that do not change the
    /// decision, so those two rows are matched by shape below.
    private static let requests: [VMCapability: VMAdmission.Request] = [
        .info: .affordance(.inspect),
        .ipAddress: .affordance(.inspect),
        .snapshots: .affordance(.inspect),
        .start: .start(recovery: false),
        .startInRecovery: .start(recovery: true),
        .cancelGuestSetup: .cancel(.guestSetup),
        .stop: .sessionAction(.requestStop),
        .restart: .sessionAction(.requestStop),
        .forceStop: .sessionAction(.forceStop),
        .discardSavedState: .operation(.discardingSavedState),
        .pause: .operation(.pausing),
        .resume: .resume,
        .suspend: .operation(.saving),
        .open: .affordance(.display),
        .reveal: .affordance(.inspect),
        .takeSnapshot: .operation(.capturingSnapshot(.stopped)),
        .deleteSnapshot: .operation(.deletingSnapshot),
        .renameSnapshot: .edit(.snapshotMetadata),
        .setSnapshotNotes: .edit(.snapshotMetadata),
        .editStorageDisks: .edit(.machineKeys),
        .createStorageDisk: .operation(.creatingStorageDisk),
        .trashStorageDisk: .operation(.removingStorageDisk),
        .editRemovableMedia: .edit(.hotPlugMedia),
        .createRemovableMedia: .operation(.creatingRemovableMedia),
        .editSharedDirectories: .edit(.machineKeys),
        .editLiveSharedDirectories: .edit(.liveShares),
        .forgetUSBPairing: .edit(.pairingRules),
        .editConfiguration: .edit(.machineKeys),
        .editLiveConfiguration: .edit(.liveKeys),
        .switchNetworkMode: .edit(.networkAttachment),
        .switchNetworkMembership: .edit(.networkMembership),
        .clone: .operation(.copyingOut(.stopped)),
        .rename: .edit(.rename),
        .delete: .operation(.deleting),
        .showInFinder: .affordance(.inspect),
        .togglePopOut: .affordance(.externalDisplay),
        .toggleFullscreen: .affordance(.externalDisplay),
        .showClipboard: .affordance(.clipboard),
        .toggleGuestAgentDisk: .affordance(.guestAgentDisk),
        .toggleSettingsPane: .affordance(.display),
    ]

    @Test("Each capability asks admission for the request the table states")
    func requestPerCapability() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        for capability in VMCapability.allCases {
            let request = capability.request(on: instance)
            switch capability {
            case .revertToSnapshot:
                guard case .operation(.bringUp(.reverting(_, resumesAfter: false)))? = request else {
                    Issue.record("\(capability) asked for \(String(describing: request))")
                    continue
                }
            case .editUSBAccessories:
                guard case .operation(.attachingUSB)? = request else {
                    Issue.record("\(capability) asked for \(String(describing: request))")
                    continue
                }
            default:
                #expect(request == Self.requests[capability], "\(capability)")
            }
        }
        #expect(Self.requests.count == VMCapability.allCases.count - 2)
    }

    @Test(
        "Take Snapshot asks for the capture the VM's settled phase takes, dimmed rather than lost during an operation")
    func takeSnapshotRequestFollowsTheSettledPhase() throws {
        let live = VMLifecyclePhase.running(sessionID: UUID())
        let cases: [(VMLifecyclePhase, VMCaptureMode?)] = [
            (.stopped, .stopped),
            (live, .live),
            (.livePaused(sessionID: UUID()), .live),
            (.failed(message: "Boot failed."), nil),
            (.initialBoot, nil),
            (.operating(.pausing, from: live), .live),
            (.operating(.deleting, from: .stopped), .stopped),
        ]
        for (phase, mode) in cases {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)
            #expect(
                VMCapability.takeSnapshot.request(on: instance)
                    == mode.map { .operation(.capturingSnapshot($0)) }, "\(phase)")
        }

        let harness = makeHarness()
        let suspended = makeInstance(in: harness, phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        #expect(
            VMCapability.takeSnapshot.request(on: suspended)
                == .operation(.capturingSnapshot(.suspended)))
    }

    @Test("Clone asks for the copy the VM's settled phase takes, dimmed rather than lost during an operation")
    func cloneRequestFollowsTheSettledPhase() throws {
        let live = VMLifecyclePhase.running(sessionID: UUID())
        let cases: [(VMLifecyclePhase, VMCaptureMode)] = [
            (.stopped, .stopped),
            (.failed(message: "Boot failed."), .stopped),
            (.initialBoot, .stopped),
            (live, .live),
            (.livePaused(sessionID: UUID()), .live),
            (.operating(.pausing, from: live), .live),
            (.operating(.deleting, from: .stopped), .stopped),
        ]
        for (phase, mode) in cases {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)
            #expect(
                VMCapability.clone.request(on: instance) == .operation(.copyingOut(mode)),
                "\(phase)")
        }

        let harness = makeHarness()
        let suspended = makeInstance(in: harness, phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        #expect(VMCapability.clone.request(on: suspended) == .operation(.copyingOut(.suspended)))
        #expect(harness.catalog.isAvailable(.clone, on: suspended))
    }

    // MARK: - The three levels

    @Test("The three levels read one decision: applicable shows it, available enables it, accepts takes it")
    func levelsReadOneDecision() {
        struct Case {
            let label: String
            let phase: VMLifecyclePhase
            let capability: VMCapability
            let applicable: Bool
            let available: Bool
            let accepted: Bool
        }
        let cases = [
            Case(
                label: "admitted", phase: .stopped, capability: .start,
                applicable: true, available: true, accepted: true),
            // Refused as busy: shown dimmed, since the VM takes it once the
            // operation ends.
            Case(
                label: "busy", phase: .operating(.deletingSnapshot, from: .stopped),
                capability: .delete, applicable: true, available: false, accepted: false),
            // Joined: never offered, taken on commit.
            Case(
                label: "joined", phase: .operating(Self.coldBoot, from: .stopped),
                capability: .start, applicable: true, available: false, accepted: true),
            Case(
                label: "invalid", phase: .stopped, capability: .pause,
                applicable: false, available: false, accepted: false),
            Case(
                label: "no request", phase: .failed(message: "Boot failed."),
                capability: .takeSnapshot, applicable: false, available: false, accepted: false),
        ]
        for testCase in cases {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: testCase.phase)
            #expect(
                harness.catalog.isApplicable(testCase.capability, to: instance)
                    == testCase.applicable, "\(testCase.label)")
            #expect(
                harness.catalog.isAvailable(testCase.capability, on: instance)
                    == testCase.available, "\(testCase.label)")
            #expect(
                harness.catalog.accepts(testCase.capability, on: instance) == testCase.accepted,
                "\(testCase.label)")
        }
    }

    /// Everything a saved state pins, because VZ restores one only into the
    /// configuration it was written under.
    private static let pinnedBySavedState: Set<VMCapability> = [
        .editStorageDisks, .editRemovableMedia, .editSharedDirectories,
        .editConfiguration, .switchNetworkMode,
    ]

    @Test("A saved state pins an at-rest VM's settings and trades its Start for Resume")
    func aSavedStateRepinsWhatAnAtRestVMOffers() throws {
        for phase: VMLifecyclePhase in [.stopped, .failed(message: "Boot failed."), .suspended] {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)

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

            try VMInstanceFixture.writeSaveFile(for: instance)

            for capability in Self.pinnedBySavedState {
                #expect(
                    !harness.catalog.isApplicable(capability, to: instance),
                    "\(capability) with a slot, \(phase)")
            }
            #expect(!harness.catalog.isApplicable(.start, to: instance), "\(phase)")
            #expect(harness.catalog.isApplicable(.resume, to: instance), "\(phase)")
            #expect(harness.catalog.isApplicable(.discardSavedState, to: instance), "\(phase)")
            // A clone carries the slot rather than being pinned out by it.
            #expect(harness.catalog.isApplicable(.clone, to: instance), "\(phase)")
            // Delete keeps working: the slot is a file inside the bundle and
            // goes with it.
            #expect(harness.catalog.isApplicable(.delete, to: instance), "\(phase)")
            // The offer names Resume; a start committed anyway restores rather
            // than being refused.
            #expect(harness.catalog.accepts(.start, on: instance), "\(phase)")
            #expect(harness.catalog.stopAction(for: instance) == .discardSavedState, "\(phase)")
        }
    }

    @Test(
        "Beside a saved state, membership switches for a Shared VM alone",
        arguments: [VMNetworkMode.shared, .hostOnly, .bridged])
    func savedStateLeavesMembershipOpenForSharedAlone(mode: VMNetworkMode) throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.networkEnabled = true
            $0.networkMode = mode
        }
        #expect(harness.catalog.isApplicable(.switchNetworkMembership, to: instance))

        try VMInstanceFixture.writeSaveFile(for: instance)

        #expect(harness.catalog.isApplicable(.switchNetworkMembership, to: instance) == (mode == .shared))
        #expect(!harness.catalog.isApplicable(.switchNetworkMode, to: instance))
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

    @Test("A revert is shown wherever a snapshot exists to revert to, and offered only on a settled VM")
    func revertToSnapshotApplicability() {
        for phase in VMLifecyclePhaseFixtures.all {
            let stockedHarness = makeHarness()
            let stocked = makeInstance(
                in: stockedHarness, phase: phase, snapshots: [VMSnapshot(name: "Clean install", macAddress: nil)])
            // An operation holding the VM dims the revert rather than hiding it.
            #expect(
                stockedHarness.catalog.isApplicable(.revertToSnapshot, to: stocked)
                    == (phase != .removed), "\(phase)")
            #expect(
                stockedHarness.catalog.isAvailable(.revertToSnapshot, on: stocked)
                    == (phase.isSettled && phase != .removed), "\(phase)")

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
        try VMInstanceFixture.writeSaveFile(for: suspended)
        #expect(harness.catalog.stopAction(for: suspended) == .discardSavedState)

        let baseline = VMSnapshot(name: "Ephemeral", macAddress: nil)
        let ephemeral = makeInstance(
            in: harness, name: "Ephemeral VM", phase: .suspended, snapshots: [baseline],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id))
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
        try VMInstanceFixture.writeSaveFile(for: suspended)
        #expect(!harness.catalog.isAvailable(.stop, on: suspended))
        #expect(harness.catalog.isAvailable(.discardSavedState, on: suspended))
        #expect(harness.catalog.isStopActionAvailable(on: suspended))

        let stopped = makeInstance(in: harness, name: "Stopped", phase: .stopped)
        #expect(!harness.catalog.isStopActionAvailable(on: stopped))
    }

    @Test("Clone stays available while a different VM is being copied")
    func cloneIgnoresAnotherVMsCopy() async {
        let harness = makeHarness()
        let settled = makeInstance(in: harness, name: "Settled")
        let gate = GatedStep()
        let copying = harness.library.beginGatedArrival(named: "Copying", gate: gate)

        // Bundle destinations are reserved atomically and overlapping copies are
        // a supported case, so one VM's copy says nothing about another's.
        #expect(harness.library.arrivals.map(\.id) == [copying.id])
        #expect(harness.catalog.isAvailable(.clone, on: settled))

        gate.release()
        await copying.settle()
    }

    // MARK: - During an operation

    @Test("Take Snapshot stays applicable but goes unavailable while an operation holds the VM")
    func takeSnapshotIsDimmedDuringAnOperation() async throws {
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
        // A resume tolerates a Force Stop, so a user can still break in on
        // it; the graceful Stop of a paused guest resumes it first, so it
        // waits the resume out.
        #expect(harness.catalog.isAvailable(.forceStop, on: instance))
        #expect(harness.catalog.isApplicable(.stop, to: instance))
        #expect(!harness.catalog.isAvailable(.stop, on: instance))
        // Nor are a snapshot's name and note held: a resume leaves the
        // manifest's metadata open.
        #expect(harness.catalog.accepts(.renameSnapshot, on: instance))
        #expect(harness.catalog.accepts(.setSnapshotNotes, on: instance))

        suspending.resumeSuspended()
        try await resume.value
    }

    // MARK: - During the termination

    @Test("Once the termination has begun, operations stay shown but go unavailable")
    func operationsAreDimmedDuringTheTermination() {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()),
            snapshots: [VMSnapshot(name: "Clean install", macAddress: nil)])

        harness.library.beginTermination()

        for capability in [VMCapability.pause, .suspend, .takeSnapshot, .revertToSnapshot] {
            #expect(harness.catalog.isApplicable(capability, to: instance), "\(capability)")
            #expect(!harness.catalog.isAvailable(capability, on: instance), "\(capability)")
            #expect(!harness.catalog.accepts(capability, on: instance), "\(capability)")
        }
        // A session action is the user's way to interrupt a guest, and a
        // plain edit starts nothing.
        #expect(harness.catalog.isAvailable(.forceStop, on: instance))
        #expect(harness.catalog.isAvailable(.rename, on: instance))
    }

    // MARK: - Bring-up: offer versus accept

    @Test("A start is taken during the bring-up it would begin, and offered during none")
    func startAcceptsAVMAlreadyComingUp() throws {
        // What lets the CLI verb that cold-launched the app join the boot the
        // launch auto-start pass began, in whichever order the two resumed. The
        // restore carries it too: a boot with a save file spends its whole
        // observable window there.
        let starting: [VMLifecyclePhase] = [
            .operating(Self.coldBoot, from: .stopped),
            .operating(Self.coldBoot, from: .stopped, boundSession: UUID()),
        ]
        for phase in starting {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)

            #expect(harness.catalog.accepts(.start, on: instance), "\(phase)")
            // Shown dimmed: the VM takes a Start once it rests again.
            #expect(harness.catalog.isApplicable(.start, to: instance), "\(phase)")
            #expect(!harness.catalog.isAvailable(.start, on: instance), "\(phase)")
        }

        let restoring: [VMLifecyclePhase] = [
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended),
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: UUID()),
        ]
        for phase in restoring {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)
            try VMInstanceFixture.writeSaveFile(for: instance)

            for capability: VMCapability in [.start, .resume] {
                #expect(harness.catalog.accepts(capability, on: instance), "\(capability) \(phase)")
                #expect(!harness.catalog.isAvailable(capability, on: instance), "\(capability) \(phase)")
            }
            // A VM holding a saved state is offered Resume, never Start.
            #expect(!harness.catalog.isApplicable(.start, to: instance), "\(phase)")
            #expect(harness.catalog.isApplicable(.resume, to: instance), "\(phase)")
        }
    }

    // MARK: - Rename

    @Test("A rename is offered and taken while an operation that leaves it open runs")
    func renameDuringAnOperationThatLeavesItOpen() {
        let live = VMLifecyclePhase.running(sessionID: UUID())
        for phase: VMLifecyclePhase in [
            .operating(.saving, from: live), .operating(Self.coldBoot, from: .stopped),
        ] {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)

            #expect(harness.catalog.isAvailable(.rename, on: instance), "\(phase)")
            #expect(harness.catalog.accepts(.rename, on: instance), "\(phase)")
        }
    }

    @Test("A revert refuses the rename it would assign back over")
    func renameRefusedDuringARevert() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: Self.reverting)

        #expect(!harness.catalog.accepts(.rename, on: instance))
    }

    /// A revert holding a VM that was stopped.
    private static let reverting = VMLifecyclePhase.operating(
        .bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped)

    @Test("Outside the joins, a commit is exactly an offer")
    func acceptanceMatchesAvailabilityElsewhere() {
        /// The pairs the two levels disagree on: each verb during the operation
        /// it joins.
        func isAnException(_ capability: VMCapability, in phase: VMLifecyclePhase) -> Bool {
            switch (capability, phase.operation?.kind) {
            case (.start, .bringUp(.guestStart(.starting(recovery: false)))?),
                (.start, .bringUp(.guestStart(.restoringSavedState))?),
                (.resume, .bringUp(.guestStart(.restoringSavedState))?),
                (.forceStop, .forceStopping?):
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
        let instance = makeInstance(in: harness, phase: Self.reverting, snapshots: [snapshot])

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
        instance.activity.placeForTesting(Self.reverting)
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
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS)

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
        // Where a pop-out or fullscreen VM reveals to, one per
        // ``VMLifecyclePhaseFixtures/all`` entry in its order. An inline VM
        // reveals into the library in every one of them, which the loop asserts
        // alongside.
        let library = VMCapabilityCatalog.RevealSurface.library
        let window = VMCapabilityCatalog.RevealSurface.displayWindow
        let detached: [VMCapabilityCatalog.RevealSurface] = [
            // stopped, initialBoot, failed, suspended, running, livePaused, removed
            library, library, library, window, window, window, library,
            // starting (unbound, bound), restoring, setting up, reverting
            library, library, window, library, window,
            // pausing, resuming, saving, capturing live, capturing disks
            window, window, window, window, window,
            // snapshot delete, USB attach, media reconcile, Force Stop, deleting
            window, window, window, window, library,
            // storage disk on a stopped VM, removable disk on a running one,
            // snapshot delete on a stopped one
            library, window, library,
        ]
        let phases = VMLifecyclePhaseFixtures.all
        #expect(detached.count == phases.count)

        for (index, (phase, expected)) in zip(phases, detached).enumerated() {
            let harness = makeHarness()
            for preference in [VMDisplayPreference.popOut, .fullscreen] {
                let instance = makeInstance(
                    in: harness, name: "VM \(index) \(preference)", phase: phase,
                    hostState: VMHostState(displayPreference: preference))
                #expect(
                    harness.catalog.revealSurface(for: instance) == expected,
                    "\(phase) \(preference)")
            }
            let inline = makeInstance(in: harness, name: "VM \(index) inline", phase: phase)
            #expect(harness.catalog.revealSurface(for: inline) == .library, "\(phase) inline")
        }
    }

    // MARK: - The guest account

    @available(macOS 27.0, *)
    @Test("The account state walks from nothing, through owed, to answered")
    func guestAccountStateWalksItsThreeStandings() {
        let harness = makeHarness()
        let intent = GuestAccountIntent(
            fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
            enablesRemoteLogin: false)
        let without = makeInstance(in: harness, phase: .stopped, guestOS: .macOS)
        #expect(harness.catalog.guestAccountState(of: without) == .none)

        // An account is set only at creation.
        let instance = makeInstance(in: harness, phase: .stopped, guestOS: .macOS) {
            $0.pendingGuestAccount = intent
        }
        #expect(harness.catalog.guestAccountState(of: instance) == .owed(intent))

        harness.library.holdGuestAccountPassword(
            GuestAccountPassword("analytical-engine"), for: instance.id)
        #expect(
            harness.catalog.guestAccountState(of: instance)
                == .answered(intent, GuestAccountPassword("analytical-engine")))
    }

    @available(macOS 27.0, *)
    @Test("A retraction leaves nothing owed and nothing held")
    func retractingEndsBothHalves() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .stopped, guestOS: .macOS) {
            $0.pendingGuestAccount = GuestAccountIntent(
                fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
                enablesRemoteLogin: false)
        }
        harness.library.holdGuestAccountPassword(
            GuestAccountPassword("analytical-engine"), for: instance.id)

        #expect(
            try instance.activity.edit(.liveKeys) { harness.library.retractGuestAccount($0) }.landed)

        // Not "asks again": the window is gone, so the question is gone with it.
        #expect(instance.configuration.pendingGuestAccount == nil)
        #expect(harness.library.heldGuestAccountPassword(for: instance) == nil)
    }

    @available(macOS 27.0, *)
    @Test("Retracting an account a VM never owed writes nothing")
    func retractingWithoutAnAccountWritesNothing() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .stopped, guestOS: .macOS)
        let writesBefore = harness.storage.saveConfigurationCallCount

        #expect(
            try instance.activity.edit(.liveKeys) { harness.library.retractGuestAccount($0) }.landed)

        #expect(harness.storage.saveConfigurationCallCount == writesBefore)
    }

    // MARK: - Shared directories

    @Test(
        "A share-list edit is offered by the rule's capability and the phase the VM is in",
        arguments: VMGuestOS.allCases)
    func sharedDirectoriesOfferPerPhase(guestOS: VMGuestOS) throws {
        let phases: [(String, VMLifecyclePhase, slot: Bool)] = [
            ("stopped", .stopped, false),
            ("suspended", .suspended, true),
            ("running", .running(sessionID: UUID()), false),
            ("paused", .livePaused(sessionID: UUID()), false),
        ]
        for (label, phase, slot) in phases {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase, guestOS: guestOS) {
                $0.sharedDirectories = [SharedDirectory(path: "/Users/Shared/one")]
            }
            if slot { try VMInstanceFixture.writeSaveFile(for: instance) }
            let add = harness.catalog.sharedDirectoriesOffer(.add, on: instance)
            let change = harness.catalog.sharedDirectoriesOffer(.change, on: instance)
            let removeLast = harness.catalog.sharedDirectoriesOffer(.remove, on: instance)
            let oneDevice = guestOS.sharesDirectoriesThroughOneDevice
            let context = "\(label) \(guestOS)"
            switch label {
            case "stopped":
                #expect(add == .offered(.editSharedDirectories), "\(context)")
                #expect(removeLast == .offered(.editSharedDirectories), "\(context)")
            case "running" where oneDevice:
                #expect(add == .offered(.editLiveSharedDirectories), "\(context)")
                #expect(change == .offered(.editLiveSharedDirectories), "\(context)")
                #expect(removeLast == .changesSharingDevice, "\(context)")
            case "running", "paused":
                let capability: VMCapability =
                    oneDevice ? .editLiveSharedDirectories : .editSharedDirectories
                #expect(add == .unavailable(capability), "\(context)")
                #expect(!removeLast.isOffered, "\(context)")
            default:
                #expect(add == .unavailable(.editSharedDirectories), "\(context)")
                #expect(removeLast == .unavailable(.editSharedDirectories), "\(context)")
            }
            #expect(
                harness.catalog.isAvailable(.editLiveSharedDirectories, on: instance)
                    == (label == "running" && oneDevice), "\(context)")
        }
    }

    @Test("A running macOS guest with no share is offered no first share")
    func runningMacOSGuestIsOfferedNoFirstShare() {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS)
        #expect(harness.catalog.sharedDirectoriesOffer(.add, on: instance) == .changesSharingDevice)
    }
}
