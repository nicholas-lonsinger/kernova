import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The command core, driven with no view model and no presenter anywhere in
/// sight: selector resolution, the state gates, the consent refusals with the
/// payload each carries, and the failures each verb reports.
@Suite("VMCommandCore Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMCommandCoreTests")

    private typealias Harness = WiredCommandCore.Scripted<MockVirtualizationService>
    /// A core whose virtualization service holds one operation suspended, so a
    /// test can look at the world while a VZ call is still in flight.
    private typealias SuspendingHarness = WiredCommandCore.Scripted<SuspendingMockVirtualizationService>

    private func makeHarness(
        virtualization: MockVirtualizationService = MockVirtualizationService(),
        diskImages: MockDiskImageService = MockDiskImageService(),
        install: any MacOSInstallProviding = MockMacOSInstallService(),
        host: FakeVirtualizationHost = FakeVirtualizationHost(),
        clock: any EngineClock = makePlatformEngineClock()
    ) -> Harness {
        Harness(
            WiredCommandCore(
                virtualization: virtualization, installService: install, diskImages: diskImages,
                preferences: preferences, virtualizationHost: host, clock: clock))
    }

    private func makeSuspendingHarness(
        clock: any EngineClock = makePlatformEngineClock()
    ) -> SuspendingHarness {
        SuspendingHarness(
            WiredCommandCore(
                virtualization: SuspendingMockVirtualizationService(), preferences: preferences, clock: clock))
    }

    @discardableResult
    private func makeInstance<Virtualization>(
        in harness: WiredCommandCore.Scripted<Virtualization>, name: String = "Core VM",
        phase: VMLifecyclePhase = .stopped, guestOS: VMGuestOS = .linux,
        snapshots: [VMSnapshot] = [], hostState: VMHostState = VMHostState(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        harness.wired.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots,
            hostState: hostState, mutate: mutate)
    }

    // MARK: - Selector resolution

    @Test("Names differing only by case are one ambiguous match, never a case-exact pick")
    func caseVariantsAreAmbiguous() throws {
        let harness = makeHarness()
        let upper = makeInstance(in: harness, name: "Sonoma")
        let lower = makeInstance(in: harness, name: "sonoma")

        for text in ["Sonoma", "sonoma", "SONOMA"] {
            let error = try #require(throws: CommandError.self) { _ = try harness.core.info(.name(text)) }
            guard case .ambiguous(_, let candidates) = error else {
                Issue.record("expected an ambiguity refusal for \(text), got \(error)")
                continue
            }
            #expect(candidates.map(\.id) == [upper.id, lower.id])
        }
    }

    // MARK: - Joining a bring-up

    @Test("A start arriving while one is in flight joins it instead of issuing a second")
    func startJoinsTheBringUpAlreadyInFlight() async throws {
        // The cold-launch race: the launch auto-start pass and the socket verb
        // resume off the same library read, and whichever runs first claims the
        // VM. Both orders have to end with the VM running.
        let harness = makeSuspendingHarness()
        let instance = makeInstance(in: harness, name: "Joining")

        let first = Task { @MainActor in
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        try await harness.virtualization.waitUntilSuspended()
        #expect(instance.status == .starting)

        // The join is entered synchronously from the call below and parks with
        // its observation armed before the main actor is given up, so this
        // release cannot land ahead of it.
        Task { @MainActor in harness.virtualization.resumeSuspended() }
        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        _ = try await first.joined()

        #expect(harness.virtualization.startCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("A start into Recovery refuses a VM already booting as busy")
    func recoveryStartRefusesAStartingVM() async throws {
        // A different target than the boot in flight, so there is nothing to
        // join — the honest answer is that the VM is busy coming up. A macOS
        // guest, since a Linux one is refused Recovery whatever it is doing.
        let harness = makeSuspendingHarness()
        let instance = makeInstance(in: harness, name: "Booting", guestOS: .macOS)

        let first = Task { @MainActor in
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        try await harness.virtualization.waitUntilSuspended()

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: true, consent: .none)
        }
        #expect({ if case .busy = error { true } else { false } }())

        harness.virtualization.resumeSuspended()
        _ = try await first.joined()
    }

    @Test("A resume arriving while a restore is in flight joins it")
    func resumeJoinsTheRestoreAlreadyInFlight() async throws {
        let harness = makeSuspendingHarness()
        let instance = makeInstance(in: harness, name: "Restoring", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)

        let first = Task { @MainActor in try await harness.core.resume(.id(instance.id), consent: .none) }
        try await harness.virtualization.waitUntilSuspended()
        #expect(instance.status == .restoring)

        Task { @MainActor in harness.virtualization.resumeSuspended() }
        try await harness.core.resume(.id(instance.id), consent: .none)
        try await first.joined()

        #expect(instance.status == .running)
    }

    // MARK: - Allowed verbs

    /// An operation that tolerates no Force Stop holds the VM, so the stop is
    /// refused before the destructive consent is ever asked for — not after
    /// taking it and doing nothing. One that started from a live VM is busy (a
    /// Force Stop is taken once it ends); a bring-up from rest had nothing to
    /// terminate.
    @Test(
        "A force stop during an operation that tolerates none asks nothing and terminates nothing",
        arguments: [
            (
                PhaseFixture.operating(
                    .bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: UUID()),
                ForceStopRefusal.invalidState(current: .restoring)
            ),
            (
                .operating(.saving, from: .running(sessionID: UUID())),
                .busy(status: .saving, operation: "suspending")
            ),
            (
                .operating(
                    .bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
                .invalidState(current: .starting)
            ),
            (
                .operating(.capturingSnapshot(.live), from: .running(sessionID: UUID())),
                .busy(status: .snapshotting, operation: "taking a snapshot")
            ),
        ])
    func forceStopRefusesWhereVirtualizationCannotStop(
        phase: PhaseFixture, expected: ForceStopRefusal
    ) async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Busy", phase: phase.phase)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.stop(
                .id(instance.id), disposition: .force, consent: .none, timeout: nil)
        }

        switch (expected, error) {
        case (.busy(let status, let operation), .busy(let vm, let actualOperation, _)):
            #expect(vm.id == instance.id)
            #expect(vm.status == status.rawValue)
            #expect(actualOperation == operation)
        case (.invalidState(let current), .invalidState(let vm, let actualCurrent, _, _, _)):
            #expect(vm.id == instance.id)
            #expect(actualCurrent == current)
        default:
            Issue.record("Expected \(expected), got \(error)")
        }
        #expect(error.confirmationPrompt == nil)
        #expect(harness.virtualization.forceStopCallCount == 0)
    }

    /// The refusal a Force Stop during an operation that tolerates none gets.
    enum ForceStopRefusal: Sendable {
        /// Taken once the operation ends: the VM's status, and what it is
        /// busy doing.
        case busy(status: VMStatus, operation: String)
        /// Nothing to terminate: the VM's status.
        case invalidState(current: VMStatus)
    }

    /// A Recovery boot is a cold boot, and a bundle holding a slot takes the
    /// restore that slot names instead — so offering Recovery there would name
    /// an outcome the bring-up will not produce, and would leave the sidebar's
    /// ⌥-alternate with no primary Start to pair with.
    @Test("A VM holding a saved state offers neither Start nor Start in Recovery")
    func recoveryIsWithheldFromAVMHoldingASavedState() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Suspended", phase: .stopped, guestOS: .macOS)
        #expect(harness.core.capabilities.isApplicable(.startInRecovery, to: instance))

        try VMInstanceFixture.writeSaveFile(for: instance)

        #expect(!harness.core.capabilities.isApplicable(.start, to: instance))
        #expect(!harness.core.capabilities.isApplicable(.startInRecovery, to: instance))
        let error = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: true, consent: .none)
        }
        guard case .unsupported = error else {
            Issue.record("expected an unsupported refusal, got \(error)")
            return
        }
        #expect(harness.virtualization.startCallCount == 0)
        #expect(instance.hasSaveFile)
    }

    // MARK: - State gates

    @Test("A state-gated verb aimed at an arrival reports busy with its copy, not an invalid state")
    func stateGatedVerbReportsBusyForAnArrival() async throws {
        let harness = makeHarness()
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(
            .cloning, named: "Copying", gate: gate)

        let error = try await #require(throws: CommandError.self) { try await harness.core.pause(.id(arrival.id)) }
        guard case .busy(let vm, let operation, _) = error else {
            Issue.record("expected a busy refusal, got \(error)")
            return
        }
        #expect(vm.id == arrival.id)
        #expect(operation == "clone")
        gate.release()
        try await arrival.settle()
    }

    // MARK: - Conflicts

    /// A running VM and a stopped twin sharing its machine identity under
    /// different MAC addresses.
    private func machineIdentityTwins(
        in harness: Harness, twinPhase: VMLifecyclePhase = .stopped
    ) -> (live: VMInstance, twin: VMInstance) {
        let identity = Data([4, 5, 6])
        let live = makeInstance(in: harness, name: "Live", phase: .running(sessionID: UUID())) {
            $0.genericMachineIdentifierData = identity
        }
        let twin = makeInstance(in: harness, name: "Twin", phase: twinPhase) {
            $0.genericMachineIdentifierData = identity
        }
        return (live, twin)
    }

    @Test("With the override on, an unconfirmed start asks, quoting Apple, and a confirmed one starts")
    func duplicateMachineIDAsksWhileTheOverrideIsOn() async throws {
        let harness = makeHarness()
        preferences.allowsDuplicateMachineIDOverride = true
        let (_, twin) = machineIdentityTwins(in: harness)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(twin.id), recovery: false, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .startBesideSharedMachineIdentity)
        #expect(prompt.title == "Start \u{201C}Twin\u{201D} with a Duplicate Machine ID?")
        #expect(
            prompt.message
                == "\u{201C}Twin\u{201D} has the same machine ID as \u{201C}Live\u{201D}, which is active. "
                + "Apple: \u{201C}Running two virtual machines concurrently with the same identifier "
                + "results in undefined behavior in the guest operating system.\u{201D}")
        #expect(prompt.confirmTitle == "Start")
        #expect(prompt.confirmIsDestructive)
        #expect(prompt.dismissTitle == "Cancel")
        #expect(harness.virtualization.startCallCount == 0)

        try await harness.core.start(
            .id(twin.id), recovery: false, consent: Consent([.startBesideSharedMachineIdentity]))
        #expect(harness.virtualization.startCallCount == 1)
    }

    @Test("A cold resume asks the same question, worded as a resume")
    func duplicateMachineIDAsksAtAColdResume() async throws {
        let harness = makeHarness()
        preferences.allowsDuplicateMachineIDOverride = true
        let (_, twin) = machineIdentityTwins(in: harness, twinPhase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: twin)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.resume(.id(twin.id), consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.title == "Resume \u{201C}Twin\u{201D} with a Duplicate Machine ID?")
        #expect(prompt.confirmTitle == "Resume")
        #expect(twin.phase == .suspended)

        try await harness.core.resume(
            .id(twin.id), consent: Consent([.startBesideSharedMachineIdentity]))
        #expect(harness.virtualization.startCallCount == 1)
    }

    @Test("A revert that resumes beside a shared machine ID asks, then reverts once confirmed")
    func revertThatResumesAsksBeforeReverting() async throws {
        let harness = makeHarness()
        preferences.allowsDuplicateMachineIDOverride = true
        let identity = Data([6, 6, 6])
        makeInstance(in: harness, name: "Twin", phase: .running(sessionID: UUID())) {
            $0.genericMachineIdentifierData = identity
        }
        let reverting = makeInstance(
            in: harness, name: "Reverting", phase: .running(sessionID: UUID())
        ) { $0.genericMachineIdentifierData = identity }
        let snapshot = VMSnapshot(name: "Before", kind: .warm, macAddress: nil)
        reverting.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        harness.machineFiles.setCapturedConfiguration(reverting.configuration, for: snapshot.id)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.revertToSnapshot(
                .id(reverting.id), snapshot: snapshot.id,
                consent: Consent([.revertToSnapshot]))
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .startBesideSharedMachineIdentity)
        #expect(prompt.title == "Resume \u{201C}Reverting\u{201D} with a Duplicate Machine ID?")
        #expect(harness.virtualization.revertedSnapshots.isEmpty)

        try await harness.core.revertToSnapshot(
            .id(reverting.id), snapshot: snapshot.id,
            consent: Consent([.revertToSnapshot, .startBesideSharedMachineIdentity]))
        #expect(harness.virtualization.revertedSnapshots.count == 1)
    }

    @Test("A force stop with no consent refuses, describing what confirming does")
    func forceStopAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Runner", phase: .running(sessionID: UUID()))

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.stop(
                .id(instance.id), disposition: .force, consent: .none, timeout: nil)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .forceStop)
        #expect(prompt.title == "Force Stop \u{201C}Runner\u{201D}?")
        #expect(prompt.confirmTitle == "Force Stop")
        #expect(prompt.confirmIsDestructive)
        #expect(
            prompt.message
                == "\u{201C}Runner\u{201D} will be immediately terminated. "
                + "Anything in the guest that isn\u{2019}t saved to disk will be lost.")
        #expect(prompt.alternatives.map(\.disposition) == [.graceful])
        // The gentler route is the one Return can safely fire.
        #expect(prompt.alternatives.map(\.isDestructive) == [false])
        #expect(harness.virtualization.forceStopCallCount == 0)

        try await harness.core.stop(.id(instance.id), disposition: .force, consent: .all, timeout: nil)
        #expect(harness.virtualization.forceStopCallCount == 1)
    }

    @Test("A graceful stop of a live-paused VM refuses as a step naming the resume, whatever the consent")
    func stopOfAPausedVMRequiresTheResume() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Paused", phase: .livePaused(sessionID: UUID()))

        // `.all` is what `--yes` sends: no consent names a resume, so none
        // can ask for one.
        let error = try await #require(throws: CommandError.self) {
            try await harness.core.stop(
                .id(instance.id), disposition: .graceful, consent: .all, timeout: nil)
        }
        #expect(
            error.stepRequirement
                == StepRequirement(
                    message:
                        "\u{201C}Paused\u{201D} is paused, so it can\u{2019}t receive a shutdown request. Resume it first, or force stop it, which loses anything in the guest that isn\u{2019}t saved to disk.",
                    routes: [
                        StepRoute(
                            title: "Resume", steps: [.resume(vm: harness.core.summary(instance))], ending: .refusedVerb)
                    ]))
        #expect(harness.virtualization.resumeCallCount == 0)
        #expect(harness.virtualization.stopCallCount == 0)
        #expect(instance.status == .paused)
    }

    @Test("A suspended VM's graceful stop asks the consent its force path does")
    func gracefulStopOfASuspendedVMAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        #expect(!harness.core.capabilities.accepts(.stop, on: instance))
        #expect(harness.core.capabilities.accepts(.discardSavedState, on: instance))

        // Not a shutdown at heart: `VirtualizationService.stop` discards the
        // save file of any VM holding one, ephemeral or not.
        let error = try await #require(throws: CommandError.self) {
            try await harness.core.stop(
                .id(instance.id), disposition: .graceful, consent: .none, timeout: nil)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .forceStop)
        #expect(prompt.title == "Discard the Saved State of \u{201C}Suspended\u{201D}?")
        #expect(prompt.confirmTitle == "Discard")
        #expect(harness.virtualization.stopCallCount == 0)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, consent: .all, timeout: nil)
        // A discard sends the guest nothing: there is no guest.
        #expect(harness.virtualization.stopCallCount == 0)
        #expect(!instance.hasSaveFile)
        #expect(instance.phase == .stopped)
    }

    @Test("A suspended Ephemeral VM's graceful stop asks the consent its force path does")
    func gracefulStopOfASuspendedEphemeralVMAsksForConsent() async throws {
        let harness = makeHarness()
        let baseline = VMSnapshot(name: "Clean install", macAddress: nil)
        let instance = makeInstance(
            in: harness, name: "Ephemeral", phase: .suspended, hostState: .ephemeral(baseline: baseline.id))
        try VMInstanceFixture.writeSaveFile(for: instance)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [baseline]))
        harness.machineFiles.setCapturedConfiguration(instance.configuration, for: baseline.id)

        // Nothing to shut down: this stop deletes the suspended session and
        // rolls the disks back, which is what the force path refuses unconfirmed.
        let error = try await #require(throws: CommandError.self) {
            try await harness.core.stop(
                .id(instance.id), disposition: .graceful, consent: .none, timeout: nil)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .forceStop)
        // Named for the outcome it produces: this VM's discard is a revert, and
        // the copy says so without claiming a discard of the VM's state.
        #expect(prompt.title == "Revert \u{201C}Ephemeral\u{201D} to \u{201C}Clean install\u{201D}?")
        #expect(prompt.confirmTitle == "Revert to Baseline")
        #expect(prompt.message.contains("is ephemeral, so it returns to"))
        #expect(harness.virtualization.revertedSnapshots.isEmpty)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, consent: .all, timeout: nil)
        #expect(harness.virtualization.revertedSnapshots.map(\.id) == [baseline.id])
    }

    @Test("A delete refuses as busy while a revert holds the VM")
    func deleteRefusedWhileARevertHoldsTheVM() async throws {
        // The revert holds the phase from its admission, through the plan read
        // and the file copy, so the catalog's answer and the delete's own
        // refusal are one decision.
        let harness = makeSuspendingHarness()
        harness.virtualization.shouldSuspendOnRevert = true
        let snapshot = VMSnapshot(name: "Clean install", macAddress: nil)
        let instance = makeInstance(
            in: harness, name: "Reverting", phase: .suspended, snapshots: [snapshot])
        harness.machineFiles.setCapturedConfiguration(instance.configuration, for: snapshot.id)

        let revert = Task { @MainActor in
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, consent: .all)
        }
        try await harness.virtualization.waitUntilSuspended()

        #expect(!harness.library.capabilities.accepts(.delete, on: instance))
        let error = try await #require(throws: CommandError.self) {
            try await harness.core.delete(
                .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
        }
        #expect({ if case .busy = error { true } else { false } }())
        #expect(harness.storage.deleteVMBundleCallCount == 0)

        harness.virtualization.resumeSuspended()
        try await revert.joined()
    }

    @Test("A permanent delete says so in the consent it asks for")
    func permanentDeletePromptNamesTheDisposition() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Doomed")

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.delete(
                .id(instance.id), permanently: true, alsoRemoving: [], consent: .none)
        }
        #expect(try #require(error.confirmationPrompt).confirmTitle == "Delete Immediately")
    }

    @Test("The delete confirmation adds the saved state and the snapshots the bundle holds")
    func deletePromptNamesTheSavedStateAndSnapshots() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Doomed")
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)

        // A bundle holding neither claims neither, and the VM heads the list it
        // belongs to rather than sitting in front of it — no comma splice.
        let bare = VMCommandCore.deletePrompt(instance, permanently: true, externals: [])
        #expect(bare.title == "Delete \u{201C}Doomed\u{201D} Immediately?")
        #expect(bare.confirmTitle == "Delete Immediately")
        #expect(
            bare.message == "\u{201C}Doomed\u{201D} and its disks will be deleted immediately, "
                + "bypassing the Trash. You can't undo this action.")

        FileManager.default.createFile(
            atPath: instance.bundleLayout.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))

        let suspended = VMCommandCore.deletePrompt(instance, permanently: true, externals: [])
        #expect(
            suspended.message == "\u{201C}Doomed\u{201D}, its disks, and its saved state will be "
                + "deleted immediately, bypassing the Trash. You can't undo this action.")
        // The trash sentence keeps the VM as its subject, so the same two items
        // join behind "with".
        let suspendedToTrash = VMCommandCore.deletePrompt(
            instance, permanently: false, externals: [])
        #expect(
            suspendedToTrash.message == "\u{201C}Doomed\u{201D} moves to the Trash with its disks "
                + "and its saved state.")

        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [VMSnapshot(name: "Before", macAddress: nil)]))

        let full = VMCommandCore.deletePrompt(instance, permanently: true, externals: [])
        #expect(full.message.contains("its disks"))
        #expect(full.message.contains("its saved state"))
        #expect(full.message.contains("its snapshots"))
    }

    @Test("A snapshot delete with no consent refuses, and confirming trashes it")
    func deleteSnapshotAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Keeper")
        let snapshot = VMSnapshot(name: "Before", macAddress: nil)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.deleteSnapshot(
                .id(instance.id), snapshot: snapshot.id, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .deleteSnapshot)
        #expect(prompt.title == "Delete \u{201C}Before\u{201D}?")
        #expect(instance.snapshotManifest.snapshots.count == 1)

        try await harness.core.deleteSnapshot(
            .id(instance.id), snapshot: snapshot.id, consent: .all)
        #expect(instance.snapshotManifest.isEmpty)
    }

    @Test("A revert with no consent refuses, offering no other route")
    func revertAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Reverter", phase: .stopped)
        let snapshot = VMSnapshot(name: "Clean", kind: .cold, macAddress: nil)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        harness.machineFiles.setCapturedConfiguration(instance.configuration, for: snapshot.id)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .revertToSnapshot)
        #expect(prompt.confirmTitle == "Revert")
        #expect(prompt.alternatives.isEmpty)
        #expect(harness.virtualization.revertedSnapshots.isEmpty)
    }

    // MARK: - Snapshots

    @Test("A snapshot the manifest no longer lists refuses by name")
    func unlistedSnapshotRefuses() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.deleteSnapshot(
                .id(instance.id), snapshot: UUID(), consent: .all)
        }
        // A refusal, not a failure: the verb never ran, so it answers the way
        // an unknown VM name does.
        guard case .itemNotFound(let vm, let item) = error else {
            Issue.record("expected a not-found refusal, got \(error)")
            return
        }
        #expect(vm.id == instance.id)
        #expect(item.hasPrefix("snapshot with the identifier"))
    }

    // MARK: - Library verbs

    @Test("A delete of a VM whose clone is still copying is refused as busy")
    func deleteRefusesASourceBeingCloned() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        let hold = DispatchSemaphore(value: 0)
        harness.storage.setCloneHold(hold)
        let clone = try await harness.core.clone(
            .id(instance.id), outcome: .newMachine, waitForOutcome: false)

        let deleteError = try await #require(throws: CommandError.self) {
            try await harness.core.delete(
                .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
        }
        guard case .busy(let vm, let operation, _) = deleteError else {
            Issue.record("expected a busy refusal, got \(deleteError)")
            return
        }
        #expect(vm.id == instance.id)
        #expect(operation == "being cloned")
        #expect(harness.library.instances.contains { $0.id == instance.id })
        hold.signal()
        try await harness.library.arrivals.first { $0.id == clone.id }?.settle()
    }

    @Test("delete refuses a VM that stopped being deletable while the sheet was up")
    func deleteRefusesANoLongerDeletableVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Started", phase: .running(sessionID: UUID()))

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.delete(
                .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
        }

        #expect(error.isInvalidState)
        #expect(harness.storage.deleteVMBundleCallCount == 0)
        #expect(harness.library.instances.count == 1)
    }

    @Test(
        "A delete answers every external that stayed once the VM is gone, and success when one is missing",
        arguments: [false, true])
    func deleteAnswersTheExternalsThatStayed(permanently: Bool) async throws {
        let harness = makeHarness()
        let paths = ["first.img", "second.iso"].map {
            scratch.url.appendingPathComponent("\(UUID().uuidString)-\($0)")
                .path(percentEncoded: false)
        }
        let disk = StorageDisk(path: paths[0], label: "First", isInternal: false)
        let media = RemovableMediaItem(path: paths[1], readOnly: true)
        let setUp: (inout VMConfiguration) -> Void = {
            $0.storageDisks = [disk]
            $0.removableMedia = [media]
        }
        let fail = { (error: CocoaError?) in
            if permanently {
                harness.fileSystem.setRemoveError(error)
            } else {
                harness.fileSystem.setTrashError(error)
            }
        }

        let ghostly = makeInstance(in: harness, name: "Ghostly", mutate: setUp)
        fail(CocoaError(.fileNoSuchFile))
        try await harness.core.delete(
            .id(ghostly.id), permanently: permanently, alsoRemoving: [disk.id, media.id],
            consent: .all)

        let target = makeInstance(in: harness, name: "Target", mutate: setUp)
        fail(CocoaError(.fileWriteNoPermission))
        let failure = try await #require(throws: CommandError.self) {
            try await harness.core.delete(
                .id(target.id), permanently: permanently, alsoRemoving: [disk.id, media.id],
                consent: .all)
        }

        // The VM went; one failed file never stops the next from being tried.
        #expect(harness.library.instances.isEmpty)
        guard case .filesKept(let kept) = failure else {
            Issue.record("expected the files-kept outcome, got \(failure)")
            return
        }
        #expect(kept.removal == .vm(name: "Target", permanently: permanently))
        #expect(Set(kept.files.map(\.path)) == Set(paths))
        #expect(harness.failures.isEmpty)
    }

    @Test("A clone copies Disk.asif only while the source still references it")
    func cloneCopiesDiskAsifOnlyWhenReferenced() async throws {
        let harness = makeHarness()
        let withMain = makeInstance(in: harness, name: "With Main") { $0.storageDisks = nil }
        _ = try await harness.core.clone(
            .id(withMain.id), outcome: .newMachine, waitForOutcome: true)
        #expect(harness.storage.lastCloneRelativePaths?.contains("Disk.asif") == true)

        let withoutMain = makeInstance(in: harness, name: "Without Main") {
            $0.storageDisks = [
                StorageDisk(path: "/tmp/external.img", label: "External", isInternal: false)
            ]
        }
        _ = try await harness.core.clone(
            .id(withoutMain.id), outcome: .newMachine, waitForOutcome: true)
        #expect(harness.storage.lastCloneRelativePaths?.contains("Disk.asif") == false)
    }

    // MARK: - The Guest Account

    private func makeAccountIntent() -> GuestAccountIntent {
        GuestAccountIntent(
            fullName: "Ada Lovelace", username: "ada", logsInAutomatically: true,
            enablesRemoteLogin: false)
    }

    /// A stopped macOS VM whose start reaches the boot directly, owing `intent`.
    private func makeBootableAccountVM(
        in harness: Harness, intent: GuestAccountIntent?
    ) -> VMInstance {
        makeInstance(in: harness, name: "Unattended VM", phase: .stopped, guestOS: .macOS) {
            $0.pendingGuestAccount = intent
        }
    }

    // MARK: - Answering for the account

    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @Test("A password the host will not take is refused, and nothing is held")
    func provideRefusesAPasswordTheHostWillNotTake() async throws {
        let hostRefusal = GuestProvisioningRefusal(field: .password, message: "Choose a longer password.")
        let harness = makeHarness(host: FakeVirtualizationHost(refusal: hostRefusal))
        let instance = makeBootableAccountVM(in: harness, intent: makeAccountIntent())
        let password = "a"

        let refusal = try #require(throws: CommandError.self) {
            try harness.core.provideGuestAccountPassword(.id(instance.id), password: password)
        }

        // The host's own wording, as an argument the caller can correct — the
        // `kernova` tool exits 2 on it.
        guard case .invalidArgument(let message) = refusal else {
            Issue.record("Expected an invalidArgument, got \(refusal)")
            return
        }
        #expect(message == hostRefusal.message)
        // Nothing held, so the question is still outstanding and the start still
        // refuses.
        #expect(harness.library.heldGuestAccountPassword(for: instance) == nil)
        #expect(harness.core.capabilities.guestAccountState(of: instance).isOwed)
        await #expect(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        #expect(harness.virtualization.startCallCount == 0)
    }

    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    // MARK: - What a start does about it

    @available(macOS 27.0, *)

    // MARK: - Restart

    @available(macOS 27.0, *)

    // MARK: - Create

    @Test("Two restarts owed to one shutdown bring the guest up once, and both succeed")
    func twoRestartsShareOneBoot() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let clock = GatedEngineClock()
        let harness = makeHarness(virtualization: virtualization, clock: clock)
        let session = UUID()
        let instance = makeInstance(
            in: harness, name: "Twice", phase: .running(sessionID: session))

        let first = Task { @MainActor in
            try await harness.core.restart(.id(instance.id), disposition: .graceful, timeout: 60, consent: .none)
        }
        // The second asks once the first's shutdown request is sent, which a
        // stop request in flight would refuse.
        try await clock.sleepRequested.wait { clock.parked.count == 1 }
        let second = Task { @MainActor in
            try await harness.core.restart(.id(instance.id), disposition: .graceful, timeout: 60, consent: .none)
        }
        // Both power-off deadlines parked: both restarts owe a boot to the
        // session's end.
        try await clock.sleepRequested.wait { clock.parked.count == 2 }

        instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        _ = try await first.joined()
        _ = try await second.joined()

        // The second boot joined the first rather than meeting the VM the
        // first brought up.
        #expect(virtualization.startCallCount == 1)
        #expect(instance.status == .running)
    }

    // MARK: - Deadlines on the power-off

    @Test("A deadline no wait can honor is refused before anything is asked of the guest")
    func anUnusableDeadlineIsRefused() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Prompt", phase: .running(sessionID: UUID()))

        for timeout in [0, -5, .infinity] as [TimeInterval] {
            let error = try await #require(throws: CommandError.self) {
                try await harness.core.stop(
                    .id(instance.id), disposition: .graceful, consent: .none, timeout: timeout)
            }
            guard case .invalidArgument = error else {
                Issue.record("Expected an argument refusal for \(timeout), got \(error)")
                continue
            }
        }
        let restart = try await #require(throws: CommandError.self) {
            try await harness.core.restart(.id(instance.id), disposition: .graceful, timeout: 0, consent: .none)
        }
        guard case .invalidArgument = restart else {
            Issue.record("Expected an argument refusal, got \(restart)")
            return
        }

        #expect(harness.virtualization.stopCallCount == 0)
        #expect(instance.status == .running)
    }

    @Test("A stop settles on the power-off, not on the baseline revert behind it")
    func stopSettlesWhileAnEphemeralRevertIsStillWriting() async throws {
        // The clock is already past the deadline the moment the wait arms, so a
        // stop that waited for anything beyond the guest going down would refuse
        // here — an Ephemeral VM's revert is Kernova's own work, not a guest
        // that would not shut down.
        let harness = makeSuspendingHarness(clock: TestEngineClock())
        harness.virtualization.shouldSuspendOnRevert = true
        let baseline = VMSnapshot(name: "Clean install", macAddress: nil)
        let instance = makeInstance(
            in: harness, name: "Ephemeral", phase: .running(sessionID: UUID()),
            hostState: .ephemeral(baseline: baseline.id))
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [baseline]))
        harness.machineFiles.setCapturedConfiguration(instance.configuration, for: baseline.id)

        try await harness.core.stop(
            .id(instance.id), disposition: .graceful, consent: .none, timeout: 60)

        // The stop answered on the power-off; the revert it started is parked
        // mid-copy behind it.
        try await harness.virtualization.waitUntilSuspended()
        #expect(!instance.hasLiveVirtualMachine)
        #expect(instance.isHeldByRevert)

        harness.virtualization.resumeSuspended()
        try await waitForChange { !instance.isHeldByRevert }
    }

    @Test("A pause landing mid-wait is not the power-off a stop is waiting for")
    func stopIsNotSettledByAPauseWhileItWaits() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let clock = GatedEngineClock()
        let harness = makeHarness(virtualization: virtualization, clock: clock)
        let instance = makeInstance(
            in: harness, name: "Stubborn", phase: .running(sessionID: UUID()))

        let stop = Task {
            try await harness.core.stop(
                .id(instance.id), disposition: .graceful, consent: .none, timeout: 60)
        }
        // The parked sleep is the deadline: once it exists the wait is armed,
        // and nothing but the predicate or that sleep can end it.
        try await clock.sleepRequested.wait { !clock.parked.isEmpty }

        try await harness.core.pause(.id(instance.id))
        #expect(instance.status == .paused)

        // A pause leaves the guest's memory live and the VM resumable. Letting
        // the deadline expire is what proves the wait was still running: had the
        // pause settled it, the stop would already have returned successfully.
        clock.release(try #require(clock.parked.first))
        let error = try await #require(throws: CommandError.self) { try await stop.joined() }
        guard case .timedOut(_, let verb, _, _) = error else {
            Issue.record("Expected a timeout refusal, got \(error)")
            return
        }
        #expect(verb == .stop)
        #expect(virtualization.forceStopCallCount == 0)
    }

    @Test("A Force Stop's deadline expires on a process that hasn't ended; every refusal meanwhile says how to end it")
    func forceStopDeadlineCarriesTheProcessEnd() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.forceStopCompletes = false
        let harness = makeHarness(virtualization: virtualization, clock: TestEngineClock())
        let session = UUID()
        let instance = makeInstance(in: harness, name: "Frozen", phase: .running(sessionID: session))
        let bundlePath = instance.bundleURL.path(percentEncoded: false)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.stop(
                .id(instance.id), disposition: .force, consent: Consent([.forceStop]), timeout: 10)
        }
        guard case .timedOut(_, let verb, let seconds, let processEnd) = error else {
            Issue.record("Expected a timeout refusal, got \(error)")
            return
        }
        #expect(verb == .stop)
        #expect(seconds == 10)
        #expect(processEnd?.command.hasSuffix(" '\(bundlePath)')") == true)
        // The expiry stops the wait, not the Force Stop.
        #expect(instance.status == .forceStopping)

        // What the VM takes once stopped is busy; the rest it refuses by
        // state. Both name the way out.
        let busy = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        guard case .busy(_, _, let busyProcessEnd) = busy else {
            Issue.record("Expected a busy refusal, got \(busy)")
            return
        }
        #expect(busyProcessEnd == processEnd)
        let refused = try await #require(throws: CommandError.self) {
            try await harness.core.suspend(.id(instance.id))
        }
        guard case .invalidState(_, let current, _, _, let refusedProcessEnd) = refused else {
            Issue.record("Expected a state refusal, got \(refused)")
            return
        }
        #expect(current == .forceStopping)
        #expect(refusedProcessEnd == processEnd)

        // The process ended from outside: the end the Force Stop asked for.
        instance.activity.deliverSessionEvent(.didStopWithError(VirtualizationError.noVirtualMachine), from: session)
        #expect(instance.status == .stopped)
        #expect(virtualization.forceStopCallCount == 1)
    }
}

extension CommandError {

    fileprivate var isInvalidState: Bool {
        if case .invalidState = self { return true }
        return false
    }
}
