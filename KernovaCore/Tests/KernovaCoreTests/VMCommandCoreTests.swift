import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import KernovaTransferProgress
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The command core, driven with no view model and no presenter anywhere in
/// sight: every verb's happy and refused paths, selector resolution, the state
/// gates, and the consent refusals with the payload each carries.
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

    @Test("Text is read as an identifier first, then as a name")
    func resolvesIDOrName() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Alpha")

        #expect(try harness.core.info(.idOrName(instance.id.uuidString)).name == "Alpha")
        #expect(try harness.core.info(.idOrName("Alpha")).name == "Alpha")
        #expect(try harness.core.info(.idOrName("alpha")).name == "Alpha")
        // A UUID nothing answers to falls back to the name lookup rather than
        // stopping at the identifier.
        #expect(
            try #require(throws: CommandError.self) { _ = try harness.core.info(.idOrName(UUID().uuidString)) }
                .isNotFound)
    }

    // MARK: - Reads

    @Test("info reports the VM's shape and status")
    func infoReportsTheVM() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Described") { $0.cpuCount = 6 }

        let info = try harness.core.info(.id(instance.id))

        #expect(info.name == "Described")
        #expect(info.status == "stopped")
        #expect(info.guestOS == "linux")
        #expect(info.cpuCount == 6)
        #expect(info.snapshotCount == 0)
        // Networking is off on the fixture, so there is no address to report.
        #expect(info.ipAddress == .unavailable)
        #expect(info.networkMode == nil)
    }

    @Test("A running VM's observed address answers info and the ip verb alike")
    func theObservedAddressAnswersEveryHeadlessRead() async throws {
        let harness = makeHarness()
        harness.vmnet.join(.common(.nat), on: "192.168.64.0")
        let instance = makeInstance(
            in: harness, name: "Addressed", phase: .running(sessionID: UUID())
        ) {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.macAddress = "aa:bb:cc:dd:ee:01"
        }

        // Running on the network but not yet seen there, and no headless read
        // invents an address meanwhile — the wait is reported as `notObserved`
        // rather than as an absence.
        #expect(try harness.core.info(.id(instance.id)).ipAddress == .notObserved)
        #expect(try harness.core.ipAddress(of: .id(instance.id)) == .notObserved)

        harness.arpTable.setTable([
            .scripted("192.168.64.4", mac: "aa:bb:cc:dd:ee:01", expiry: ARPEntry.freshExpiry)
        ])
        await harness.library.guestAddresses.readForTesting()

        #expect(try harness.core.info(.id(instance.id)).ipAddress == .observed("192.168.64.4"))
        #expect(try harness.core.ipAddress(of: .id(instance.id)) == .observed("192.168.64.4"))
    }

    @Test("snapshots answers the manifest newest first")
    func snapshotsAreNewestFirst() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let older = VMSnapshot(name: "Older", createdAt: Date(timeIntervalSince1970: 1), macAddress: nil)
        let newer = VMSnapshot(name: "Newer", createdAt: Date(timeIntervalSince1970: 2), macAddress: nil)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [older, newer], currentID: newer.id))

        let listed = try harness.core.snapshots(of: .id(instance.id))

        #expect(listed.map(\.name) == ["Newer", "Older"])
        #expect(listed.first?.isCurrent == true)
        #expect(listed.allSatisfy { !$0.isEphemeralBaseline })
    }

    // MARK: - Lifecycle happy paths

    /// The core asks on every bring-up, saying only whether someone asked for
    /// this VM: what a readying costs on screen is the adapter's decision.
    @Test("resume and restart ready the display too")
    func everyBringUpReadiesTheDisplay() async throws {
        let harness = makeHarness()
        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        let running = makeInstance(
            in: harness, name: "Running", phase: .running(sessionID: UUID()))
        var readied: [UUID] = []
        var presences: [VMBringUpPresence] = []
        harness.core.readyDisplay = {
            readied.append($0.id)
            presences.append($1)
        }

        try await harness.core.resume(.id(suspended.id), consent: .none)
        try await harness.core.restart(.id(running.id), disposition: .graceful, timeout: nil, consent: .none)

        #expect(readied == [suspended.id, running.id])
        #expect(presences == [.attended, .attended])
        #expect(harness.surfacedDisplays.isEmpty)
    }

    @Test("reveal of an arrival still being copied lands on its library row")
    func revealOfAnArrivalLandsInTheLibrary() async throws {
        let harness = makeHarness()
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(named: "Copying", gate: gate)

        try harness.core.reveal(.id(arrival.id))

        #expect(harness.revealedInLibrary == [arrival.id])
        #expect(harness.surfacedDisplays.isEmpty)
        gate.release()
        await arrival.settle()
    }

    /// What a surfacing verb did, in order, under an installed requester.
    @MainActor
    private final class SurfaceSteps {
        var steps: [String] = []
    }

    @Test("open and reveal ask the request's requester once, just before they surface")
    func surfacingVerbsAskTheRequesterBeforeSurfacing() throws {
        let harness = makeHarness()
        let running = makeInstance(in: harness, name: "Running", phase: .running(sessionID: UUID()))
        let stopped = makeInstance(in: harness, name: "Stopped")
        let trace = SurfaceSteps()
        harness.core.surfaceDisplay = { trace.steps.append("display \($0.name)") }
        harness.core.revealInLibrary = { id in
            let name = harness.library.entries.first { $0.id == id }?.name ?? "?"
            trace.steps.append("library \(name)")
        }
        let requester = ActivationRequester { trace.steps.append("activate") }

        try ActivationRequester.$current.withValue(requester) {
            try harness.core.open(.id(running.id))
            try harness.core.reveal(.id(stopped.id))
        }

        #expect(
            trace.steps == ["activate", "display Running", "activate", "library Stopped"])
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
        await harness.virtualization.waitUntilSuspended()
        #expect(instance.status == .starting)

        // The join is entered synchronously from the call below and parks with
        // its observation armed before the main actor is given up, so this
        // release cannot land ahead of it.
        Task { @MainActor in harness.virtualization.resumeSuspended() }
        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        try await first.value

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
        await harness.virtualization.waitUntilSuspended()

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: true, consent: .none)
        }
        #expect(error.isBusy)

        harness.virtualization.resumeSuspended()
        try await first.value
    }

    @Test("A resume arriving while a restore is in flight joins it")
    func resumeJoinsTheRestoreAlreadyInFlight() async throws {
        let harness = makeSuspendingHarness()
        let instance = makeInstance(in: harness, name: "Restoring", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)

        let first = Task { @MainActor in try await harness.core.resume(.id(instance.id), consent: .none) }
        await harness.virtualization.waitUntilSuspended()
        #expect(instance.status == .restoring)

        Task { @MainActor in harness.virtualization.resumeSuspended() }
        try await harness.core.resume(.id(instance.id), consent: .none)
        try await first.value

        #expect(instance.status == .running)
    }

    @Test("A failed resume offers the attachment removal a failed start offers")
    func resumeFailureCarriesTheAttachmentRecovery() async throws {
        let harness = makeHarness()
        let item = RemovableMediaItem(path: "/tmp/gone.iso", readOnly: true, label: "Installer")
        let instance = makeInstance(in: harness, name: "Suspended", phase: .suspended) {
            $0.removableMedia = [item]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)
        // A restore assembles the same configuration a boot does, so it fails
        // over an unopenable attachment in the same way.
        harness.virtualization.startError = ConfigurationBuilderError.removableMediaAttachFailed(
            id: item.id, path: item.path, label: item.label,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.resume(.id(instance.id), consent: .none)
        }

        guard case .operationFailed(let verb, _, _, let recovery) = error,
            case .removeStartFailedAttachment(let offered) = recovery
        else {
            Issue.record("expected a removable-attachment recovery, got \(error)")
            return
        }
        #expect(verb == .resume)
        #expect(offered.verb == .resume)
        #expect(offered.id == item.id)
        // The saved state is kept, and the VM rests where a Resume is offered.
        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
    }

    @Test("A failed resume over a shared folder offers that share's removal")
    func resumeFailureOverASharedFolderCarriesTheRecovery() async throws {
        let harness = makeHarness()
        let share = SharedDirectory(path: "/Volumes/Ext/Projects")
        let instance = makeInstance(in: harness, name: "Suspended", phase: .suspended) {
            $0.sharedDirectories = [share]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)
        harness.virtualization.startError = ConfigurationBuilderError.sharedDirectoryNotReadable(
            id: share.id, path: share.path, label: share.displayName)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.resume(.id(instance.id), consent: .none)
        }

        guard case .operationFailed(let verb, _, _, let recovery) = error,
            case .removeStartFailedAttachment(let offered) = recovery
        else {
            Issue.record("expected a removable-attachment recovery, got \(error)")
            return
        }
        #expect(verb == .resume)
        #expect(offered.kind == .sharedDirectory)
        #expect(offered.reason == .notReadable)
        #expect(offered.id == share.id)
        #expect(offered.label == "Projects")
        #expect(instance.hasSaveFile)
    }

    // MARK: - Allowed verbs

    @Test("allowedVerbs reads out in a fixed order, reads first")
    func allowedVerbsOrder() {
        let harness = makeHarness()
        let stopped = makeInstance(in: harness, name: "Stopped", phase: .stopped)

        // The order is user-visible: `invalidState` renders this list as
        // "What it accepts now: Start, Take Snapshot, …".
        #expect(
            harness.core.allowedVerbs(for: stopped) == [
                .info, .ipAddress, .snapshots, .start, .reveal, .takeSnapshot, .deleteSnapshot,
                .renameSnapshot, .setSnapshotNotes, .editStorageDisk, .editRemovableMedia,
                .editSharedDirectory, .setConfiguration, .clone, .rename,
                .delete, .showInFinder,
            ])

        let running = makeInstance(
            in: harness, name: "Running", phase: .running(sessionID: UUID()))
        #expect(
            harness.core.allowedVerbs(for: running) == [
                .info, .ipAddress, .snapshots, .stop, .restart, .pause, .suspend, .open, .reveal,
                .takeSnapshot, .deleteSnapshot, .renameSnapshot, .setSnapshotNotes,
                .editRemovableMedia, .setConfiguration, .clone, .rename, .showInFinder,
            ])
    }

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
                .id(instance.id), disposition: .force, consent: .none)
        }

        switch (expected, error) {
        case (.busy(let status, let operation), .busy(let vm, let actualOperation)):
            #expect(vm.id == instance.id)
            #expect(vm.status == status.rawValue)
            #expect(actualOperation == operation)
        case (.invalidState(let current), .invalidState(let vm, let actualCurrent, _, _)):
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

    /// Only a cold boot creates the account, so a restore must not be turned
    /// back for one nobody answered — the session it resumes was set up long
    /// ago.
    @Test("A start that restores a saved state asks for no guest account")
    func aRestoringStartDoesNotAskForTheGuestAccount() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Suspended", phase: .suspended, guestOS: .macOS
        ) {
            $0.pendingGuestAccount = GuestAccountIntent(
                fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
                enablesRemoteLogin: false)
        }
        try VMInstanceFixture.writeSaveFile(for: instance)

        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)

        #expect(harness.virtualization.startCallCount == 1)
        #expect(harness.virtualization.lastStartRoute == .restoredSavedState)
        // Nothing was handed over, and the question is still the next cold
        // boot's to ask.
        #expect(harness.virtualization.lastStartProvisioning == nil)
        #expect(instance.configuration.pendingGuestAccount != nil)
    }

    // MARK: - State gates

    @Test("A state-gated verb aimed at an arrival reports busy with its copy, not an invalid state")
    func stateGatedVerbReportsBusyForAnArrival() async throws {
        let harness = makeHarness()
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(
            .cloning, named: "Copying", gate: gate)

        let error = try await #require(throws: CommandError.self) { try await harness.core.pause(.id(arrival.id)) }
        guard case .busy(let vm, let operation) = error else {
            Issue.record("expected a busy refusal, got \(error)")
            return
        }
        #expect(vm.id == arrival.id)
        #expect(operation == "clone")
        gate.release()
        await arrival.settle()
    }

    @Test("cancelGuestSetup without consent refuses with the confirmation naming the running step")
    func cancelGuestSetupWithoutConsentNamesTheStep() throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness,
            phase: .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot))
        instance.setupState = .macOSInstall(hasDownloadStep: true)

        let error = try #require(throws: CommandError.self) {
            try harness.core.cancelGuestSetup(.id(instance.id), consent: .none)
        }
        guard case .confirmationRequired(let prompt) = error else {
            Issue.record("expected a consent refusal, got \(error)")
            return
        }
        #expect(prompt.kind == .cancelGuestSetup)
        #expect(prompt.title == "Cancel Download?")
    }

    @Test("cancelGuestSetup's prompt names what a cancel costs at each step")
    func cancelGuestSetupPromptVariesByStep() {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness,
            phase: .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot))

        instance.setupState = .macOSInstall(hasDownloadStep: false)
        let install = VMCommandCore.cancelGuestSetupPrompt(instance)
        #expect(install.title == "Cancel Installation?")
        #expect(install.confirmTitle == "Cancel Installation")
        #expect(install.dismissTitle == "Keep Installing")
        // Only the install throws work away: its progress restarts from zero.
        #expect(install.confirmIsDestructive)

        instance.setupState = .linuxImage(digestSource: .enteredByUser)
        instance.setupState?.advance(progress: .fraction(0))
        let verify = VMCommandCore.cancelGuestSetupPrompt(instance)
        #expect(verify.title == "Cancel Verification?")
        #expect(verify.confirmTitle == "Cancel Verification")
        #expect(verify.dismissTitle == "Keep Verifying")
        #expect(!verify.confirmIsDestructive)

        instance.setupState = .linuxImage(digestSource: nil)
        instance.setupState?.advance(progress: .fraction(0))
        let checksum = VMCommandCore.cancelGuestSetupPrompt(instance)
        #expect(checksum.title == "Cancel Checksum?")
        #expect(
            checksum.message
                == "The downloaded image is kept, and its checksum will be computed the next time you start the virtual machine."
        )
        #expect(checksum.confirmTitle == "Cancel Checksum")
        #expect(checksum.dismissTitle == "Keep Computing")
        #expect(!checksum.confirmIsDestructive)

        instance.setupState = .macOSInstall(hasDownloadStep: true)
        let download = VMCommandCore.cancelGuestSetupPrompt(instance)
        #expect(download.title == "Cancel Download?")
        #expect(download.confirmTitle == "Cancel Download")
        #expect(download.dismissTitle == "Keep Downloading")
        #expect(!download.confirmIsDestructive)

        instance.setupState = nil
        let fallback = VMCommandCore.cancelGuestSetupPrompt(instance)
        #expect(fallback.title == "Cancel Download?")
        #expect(fallback.dismissTitle == "Keep Downloading")
        #expect(!fallback.confirmIsDestructive)
    }

    @Test("A cancel accepted as the pipeline finishes stops the chained auto-boot")
    func cancelAtTheTailOfSetupDoesNotBoot() async throws {
        // Returns normally once released, so the pipeline succeeds *after* the
        // cancel lands — the window a `CancellationError` never reports.
        let installService = ReleasableMockMacOSInstallService()
        let harness = makeHarness(install: installService)
        let core = harness.core
        let instance = harness.library.registerFixture(
            name: "Installing", guestOS: .macOS, phase: .initialBoot, preferences: preferences
        ) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }

        try await core.start(.id(instance.id), recovery: false, consent: .none)
        for await _ in installService.installStartedStream { break }

        try core.cancelGuestSetup(.id(instance.id), consent: .all)
        installService.release()
        await instance.setupOperationTask?.value

        #expect(harness.virtualization.startCallCount == 0)
        #expect(instance.status == .initialBoot)
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

    @Test("Naming no virtual machine, the question reads as a start's does")
    func duplicateMachineIDQuestionNamingNoVM() {
        let prompt = DuplicateMachineIDQuestion.prompt(verb: nil, names: nil)

        #expect(prompt.title == "Start with a Duplicate Machine ID?")
        #expect(
            prompt.message
                == "This virtual machine has the same machine ID as another, which is active. "
                + "Apple: \u{201C}Running two virtual machines concurrently with the same identifier "
                + "results in undefined behavior in the guest operating system.\u{201D}")
        #expect(prompt.message.hasSuffix(DuplicateMachineIDQuestion.vendorClaim))
        #expect(prompt.kind == .startBesideSharedMachineIdentity)
    }

    @Test("With the question dismissed, a start and a restart beside a shared machine ID go ahead without consent")
    func dismissedQuestionStartsWithoutConsent() async throws {
        let harness = makeHarness()
        preferences.allowsDuplicateMachineIDOverride = true
        preferences.duplicateMachineIDQuestionDismissed = true
        let (_, twin) = machineIdentityTwins(in: harness)

        // What `kernova start` sends without --yes.
        try await harness.core.start(.id(twin.id), recovery: false, consent: .none)
        #expect(harness.virtualization.startCallCount == 1)
        #expect(twin.status == .running)

        // And `kernova restart`, whose boot runs with nobody to ask.
        try await harness.core.restart(.id(twin.id), disposition: .graceful, timeout: nil, consent: .none)
        #expect(harness.virtualization.startCallCount == 2)
        #expect(twin.status == .running)
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

    @Test("Restart beside a shared machine ID asks before the guest goes down, and restarts once confirmed")
    func restartAsksBeforeTheStop() async throws {
        let harness = makeHarness()
        preferences.allowsDuplicateMachineIDOverride = true
        let identity = Data([4, 4, 4])
        makeInstance(in: harness, name: "Twin", phase: .running(sessionID: UUID())) {
            $0.genericMachineIdentifierData = identity
        }
        let restarting = makeInstance(
            in: harness, name: "Restarting", phase: .running(sessionID: UUID())
        ) { $0.genericMachineIdentifierData = identity }

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.restart(.id(restarting.id), disposition: .graceful, timeout: nil, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .startBesideSharedMachineIdentity)
        #expect(prompt.title == "Restart \u{201C}Restarting\u{201D} with a Duplicate Machine ID?")
        #expect(prompt.confirmTitle == "Restart")
        // Asked while the guest is still up.
        #expect(harness.virtualization.stopCallCount == 0)
        #expect(restarting.status == .running)

        try await harness.core.restart(
            .id(restarting.id), disposition: .graceful, timeout: nil,
            consent: Consent([.startBesideSharedMachineIdentity]))
        #expect(harness.virtualization.startCallCount == 1)
        #expect(restarting.status == .running)
    }

    @Test("A warm revert of a live VM onto a MAC address another live VM holds is refused at admission")
    func warmRevertOntoALiveMACAddressIsRefusedAtAdmission() async throws {
        let harness = makeHarness()
        let heldMAC = "aa:bb:cc:dd:ee:10"
        let holder = makeInstance(
            in: harness, name: "Holder", phase: .running(sessionID: UUID())
        ) {
            $0.networkEnabled = true
            $0.macAddress = heldMAC
        }
        let reverting = makeInstance(
            in: harness, name: "Reverting", phase: .running(sessionID: UUID())
        ) {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:11"
        }
        // Captured while the VM still carried the address the holder has since
        // taken: the revert puts it back, and the resume that follows would put
        // it on the holder's network.
        let snapshot = VMSnapshot(name: "Before", kind: .warm, macAddress: heldMAC)
        reverting.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        var captured = reverting.configuration
        captured.macAddress = heldMAC
        harness.machineFiles.setCapturedConfiguration(captured, for: snapshot.id)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.revertToSnapshot(
                .id(reverting.id), snapshot: snapshot.id, consent: .all)
        }

        let requirement = try #require(error.stepRequirement)
        #expect(requirement.title == "Duplicate MAC Address")
        #expect(requirement.routes.isEmpty)
        #expect(requirement.message.contains("\u{201C}\(holder.name)\u{201D}"))
        // Refused before the live guest was torn down or a file moved.
        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(reverting.status == .running)
        #expect(!reverting.hasSaveFile)
        #expect(reverting.configuration.macAddress == "aa:bb:cc:dd:ee:11")
        #expect(reverting.snapshotManifest.currentID == nil)
        #expect(holder.status == .running)
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

    @Test("A start owing guest setup onto a live identity is refused before the installer runs")
    func setupStartOntoALiveIdentityIsRefusedBeforeTheInstaller() async throws {
        let install = MockMacOSInstallService()
        let harness = makeHarness(install: install)
        let holder = makeInstance(
            in: harness, name: "Holder", phase: .running(sessionID: UUID()), guestOS: .macOS
        ) {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:20"
        }
        let pending = makeInstance(
            in: harness, name: "Pending", phase: .initialBoot, guestOS: .macOS
        ) {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:20"
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
        }

        // Refused at admission, so the refusal is the start's own answer
        // rather than a failure the setup reports later.
        let error = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(pending.id), recovery: false, consent: .none)
        }

        #expect(install.installCallCount == 0)
        #expect(harness.virtualization.startCallCount == 0)
        #expect(pending.status == .initialBoot)
        #expect(harness.failures.isEmpty)
        let requirement = try #require(error.stepRequirement)
        #expect(requirement.message.hasPrefix("\u{201C}\(pending.name)\u{201D}"))
        #expect(requirement.message.contains("\u{201C}\(holder.name)\u{201D}"))
    }

    @Test("A force stop with no consent refuses, describing what confirming does")
    func forceStopAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Runner", phase: .running(sessionID: UUID()))

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.stop(
                .id(instance.id), disposition: .force, consent: .none)
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

        try await harness.core.stop(.id(instance.id), disposition: .force, consent: .all)
        #expect(harness.virtualization.forceStopCallCount == 1)
    }

    @Test("A suspended VM's force stop is worded as discarding its saved state")
    func forceStopOfASuspendedVMIsADiscard() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.stop(
                .id(instance.id), disposition: .force, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.title == "Discard the Saved State of \u{201C}Suspended\u{201D}?")
        #expect(prompt.confirmTitle == "Discard")
        // Nothing is live to receive a shutdown, so none is offered.
        #expect(prompt.alternatives.isEmpty)

        // Nothing is live to terminate, and the verb still performs the discard
        // the slot admits.
        try await harness.core.stop(.id(instance.id), disposition: .force, consent: .all)
        #expect(harness.virtualization.forceStopCallCount == 0)
        #expect(!instance.hasSaveFile)
        #expect(instance.phase == .stopped)
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
                .id(instance.id), disposition: .graceful, consent: .all)
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

    @Test("A restart of a paused VM resumes it, shuts it down, and boots it")
    func restartOfAPausedVMStillRestarts() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Paused", phase: .livePaused(sessionID: UUID()))

        try await harness.core.restart(.id(instance.id), disposition: .graceful, timeout: nil, consent: .none)

        #expect(harness.virtualization.resumeCallCount == 1)
        #expect(harness.virtualization.stopCallCount == 1)
        #expect(harness.virtualization.startCallCount == 1)
        #expect(instance.status == .running)
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
                .id(instance.id), disposition: .graceful, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .forceStop)
        #expect(prompt.title == "Discard the Saved State of \u{201C}Suspended\u{201D}?")
        #expect(prompt.confirmTitle == "Discard")
        #expect(harness.virtualization.stopCallCount == 0)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, consent: .all)
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
                .id(instance.id), disposition: .graceful, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .forceStop)
        // Named for the outcome it produces: this VM's discard is a revert, and
        // the copy says so without claiming a discard of the VM's state.
        #expect(prompt.title == "Revert \u{201C}Ephemeral\u{201D} to \u{201C}Clean install\u{201D}?")
        #expect(prompt.confirmTitle == "Revert to Baseline")
        #expect(prompt.message.contains("is ephemeral, so it returns to"))
        #expect(harness.virtualization.revertedSnapshots.isEmpty)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, consent: .all)
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
        await harness.virtualization.waitUntilSuspended()

        #expect(!harness.library.capabilities.accepts(.delete, on: instance))
        let error = try await #require(throws: CommandError.self) {
            try await harness.core.delete(
                .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
        }
        #expect(error.isBusy)
        #expect(harness.storage.deleteVMBundleCallCount == 0)

        harness.virtualization.resumeSuspended()
        try await revert.value
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

    @Test("The delete confirmation names external files only when one can be chosen")
    func deletePromptNamesChoosableExternalsOnly() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Doomed")
        let owned = makeExternalAttachment(label: "Scratch", path: "/tmp/scratch.img")
        let shared = makeExternalAttachment(
            label: "Installer", path: "/tmp/installer.iso", sharedWith: ["Other VM"])

        // A locked-off row offers no choice, so promising to take it would be
        // wrong in both dispositions.
        for permanently in [true, false] {
            let none = VMCommandCore.deletePrompt(
                instance, permanently: permanently, externals: [shared])
            #expect(!none.message.contains("external files"))

            let offered = VMCommandCore.deletePrompt(
                instance, permanently: permanently, externals: [shared, owned])
            #expect(offered.message.contains("any external files you choose"))
        }

        // The clause sits inside each sentence rather than trailing it.
        let immediate = VMCommandCore.deletePrompt(
            instance, permanently: true, externals: [owned])
        #expect(
            immediate.message == "\u{201C}Doomed\u{201D} and its disks, plus any external files "
                + "you choose, will be deleted immediately, bypassing the Trash. You can't undo "
                + "this action.")
        let trash = VMCommandCore.deletePrompt(instance, permanently: false, externals: [owned])
        #expect(
            trash.message == "\u{201C}Doomed\u{201D} moves to the Trash with its disks, and any "
                + "external files you choose.")
    }

    private func makeExternalAttachment(
        label: String, path: String, sharedWith: [String] = [], isMissing: Bool = false
    ) -> ExternalAttachment {
        ExternalAttachment(
            reference: ExternalFileReference(
                id: UUID(), kind: .storageDisk, label: label, path: path, bookmark: nil, readOnly: false),
            sharedWithVMNames: sharedWith,
            isMissing: isMissing)
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

    @Test("A cancel with no consent refuses, and confirming marks the row cancelling")
    func cancelPreparingAsksForConsent() async throws {
        let harness = makeHarness()
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(
            .cloning, named: "Copying", gate: gate)

        let error = try #require(throws: CommandError.self) {
            try harness.core.cancelPreparing(.id(arrival.id), consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .cancelPreparing)
        #expect(prompt.confirmTitle == "Cancel Clone")
        #expect(arrival.stage == .writing)

        try harness.core.cancelPreparing(.id(arrival.id), consent: .all)
        #expect(arrival.stage == .cancelling)
        #expect(arrival.displayLabel == "Cancelling\u{2026}")

        // The row stays until the uninterruptible write settles, then leaves
        // with what it wrote.
        #expect(harness.library.entries.contains { $0.id == arrival.id })
        gate.release()
        #expect(await arrival.settle() == nil)
        #expect(!harness.library.entries.contains { $0.id == arrival.id })
        #expect(harness.storage.discardedStagedURLs == harness.storage.stagedBundleURLs)
        #expect(harness.storage.publishBundleCallCount == 0)
    }

    // MARK: - Snapshots

    @Test("A capture lands in the manifest, stamped by what the VM could capture")
    func takeSnapshotLandsInTheManifest() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        let summary = try await harness.core.takeSnapshot(
            .id(instance.id), name: "  Fresh  ", notes: " a note ")

        #expect(summary.name == "Fresh")
        #expect(summary.notes == "a note")
        #expect(summary.kind == "warm")
        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Fresh"])
    }

    @Test("A stopped VM whose guest can write an external disk is snapshotted as before")
    func writableExternalDiskLeavesAStoppedSnapshotAlone() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness) {
            $0.storageDisks = [
                StorageDisk(path: "Disk.asif", isInternal: true),
                StorageDisk(path: "/Volumes/Data/Shared.asif", readOnly: false),
            ]
        }
        #expect(instance.snapshotCaptureMode == .stopped)

        let summary = try await harness.core.takeSnapshot(.id(instance.id), name: "Cold", notes: "")

        #expect(summary.kind == "cold")
        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Cold"])
    }

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

    @Test("A metadata edit that would change nothing is a no-op, snapshot listed or not")
    func snapshotMetadataNoOpNeedsNoSnapshot() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let snapshot = VMSnapshot(name: "Kept", notes: "a note", macAddress: nil)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))

        // Unchanged commits against a listed snapshot write nothing.
        #expect(throws: Never.self) {
            try harness.core.renameSnapshot(.id(instance.id), snapshot: snapshot.id, to: "Kept")
        }
        #expect(throws: Never.self) {
            try harness.core.setSnapshotNotes(
                .id(instance.id), snapshot: snapshot.id, notes: "a note")
        }

        // The row can be deleted while its field editor is open, and the
        // end-editing commit that follows names a snapshot that is gone: still
        // nothing to write, so still no alert naming a raw identifier.
        let gone = UUID()
        #expect(throws: Never.self) {
            try harness.core.renameSnapshot(.id(instance.id), snapshot: gone, to: "Kept")
        }
        #expect(throws: Never.self) {
            try harness.core.setSnapshotNotes(.id(instance.id), snapshot: gone, notes: "a note")
        }
        #expect(instance.fixtureBundleFiles.replaceCount(of: VMBundleLayout.snapshotManifestRelativePath) == 0)
    }

    // MARK: - Library verbs

    @Test("rename writes the trimmed name through the configuration funnel")
    func renameWritesThrough() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Before")

        try harness.core.rename(.id(instance.id), to: "  After  ")

        #expect(instance.name == "After")
    }

    @Test("rename lands on a VM that started transitioning while the field was open")
    func renamePersistsThroughATransition() throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Before", phase: .operating(.saving, from: .running(sessionID: UUID())))

        // The rename rewrites the configuration's name and nothing the suspend
        // reads, so the typed name lands rather than being traded for an alert.
        try harness.core.rename(.id(instance.id), to: "After")

        #expect(instance.name == "After")
        #expect(harness.core.allowedVerbs(for: instance).contains(.rename))
    }

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
        guard case .busy(let vm, let operation) = deleteError else {
            Issue.record("expected a busy refusal, got \(deleteError)")
            return
        }
        #expect(vm.id == instance.id)
        #expect(operation == "being cloned")
        #expect(harness.library.instances.contains { $0.id == instance.id })
        hold.signal()
        await harness.library.arrivals.first { $0.id == clone.id }?.settle()
    }

    @Test("A repeat delete of an already-removed VM refuses as not found")
    func deleteRefusesARepeatConfirm() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Doomed")

        try await harness.core.delete(
            .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
        let error = try await #require(throws: CommandError.self) {
            try await harness.core.delete(
                .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
        }

        #expect(error.isNotFound)
        #expect(harness.storage.deleteVMBundleCallCount == 1)
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

    @Test("delete never removes an external another VM still references")
    func deleteKeepsSharedExternals() async throws {
        let harness = makeHarness()
        let sharedPath = scratch.url
            .appendingPathComponent("shared.img")
            .path(percentEncoded: false)
        let sharedID = UUID()
        let target = makeInstance(in: harness, name: "Target") {
            $0.storageDisks = [
                StorageDisk(
                    id: sharedID, path: sharedPath, readOnly: false, label: "Shared",
                    isInternal: false, kind: .virtio)
            ]
        }
        makeInstance(in: harness, name: "Other") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath, readOnly: false, label: "Shared", isInternal: false,
                    kind: .virtio)
            ]
        }

        try await harness.core.delete(
            .id(target.id), permanently: false, alsoRemoving: [sharedID], consent: .all)

        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(harness.fileSystem.removedURLs.isEmpty)
    }

    @Test("A permanent delete of an external bypasses the Trash")
    func permanentDeleteRemovesExternalsOutright() async throws {
        let harness = makeHarness()
        let externalPath = scratch.url
            .appendingPathComponent("external.img")
            .path(percentEncoded: false)
        let diskID = UUID()
        let instance = makeInstance(in: harness, name: "Target") {
            $0.storageDisks = [
                StorageDisk(
                    id: diskID, path: externalPath, readOnly: false, label: "External",
                    isInternal: false, kind: .virtio)
            ]
        }

        try await harness.core.delete(
            .id(instance.id), permanently: true, alsoRemoving: [diskID], consent: .all)

        #expect(harness.fileSystem.removedURLs.map(\.path) == [externalPath])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(harness.storage.permanentlyDeleteVMBundleCallCount == 1)
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

    /// A `.kernova`-shaped source with its `config.json` on disk, under a
    /// per-call parent, because the import copies real files.
    @Test("An import takes the bundle the authority answered with, not the path asked about")
    func importGoesThroughTheAuthority() async throws {
        let harness = makeHarness()
        let picked = try scratch.importSource(name: "Picked").url
        harness.authority.substitute = picked

        let summary = try await harness.core.importVM(
            atPath: "/Users/somebody/Desktop/Asked.kernova", waitForOutcome: true)

        #expect(harness.authority.requests.map(\.source) == [.vmBundle])
        #expect(
            harness.authority.requestedURLs.map { $0.path(percentEncoded: false) }
                == ["/Users/somebody/Desktop/Asked.kernova"])
        // Nothing answers for the asked-about path, so an import that read it
        // instead of the picked bundle would have failed rather than named one.
        #expect(summary.name == "Picked")
        #expect(harness.library.instances.map(\.name) == ["Picked"])
    }

    @Test("An imported bundle's pairings are live once it publishes")
    func importTakesOnTheBundlesPairings() async throws {
        let harness = makeHarness()
        let source = try scratch.importSource(name: "Paired").url
        let pairing = USBAccessoryPairing(
            key: "0403:6001:0100:0373", form: .serialNumber, displayName: "Samsung Type-C",
            receptacleLabel: nil)
        try VMStagedBundle.fixtureForTesting(at: source, access: CoordinatedBundleFileAccess()).update(.usbPairings) {
            $0 = USBAccessoryPairingSet(pairings: [pairing])
        }

        _ = try await harness.core.importVM(from: source, waitForOutcome: true)

        let imported = try #require(harness.library.instances.first)
        #expect(harness.library.arrivals.isEmpty)
        #expect(imported.usbPairings.pairings.map(\.key) == [pairing.key])
    }

    // MARK: - Storage Disk Lookup

    @Test("storageDisk(id:on:) resolves the synthesized main disk over an empty configured list")
    func storageDiskLookupResolvesSynthesizedMainDiskForEmptyList() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness) { $0.storageDisks = [] }

        let mainDisk = StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: instance.bundleURL))

        #expect(harness.core.storageDisk(id: mainDisk.id, on: instance) == mainDisk)
    }

    // MARK: - Application

    @Test("The quit verb asks the adapter once, on a later turn than the call")
    func quitDefersToTheAdapter() async throws {
        let harness = makeHarness()
        harness.core.quit()

        // Deferred: a transport waiting on this verb has to get its
        // answer written before the process starts going down.
        #expect(harness.quitRequests == 0)

        try await harness.quitRequested.wait { harness.quitRequests == 1 }
        #expect(harness.quitRequests == 1)
    }

    // MARK: - Events

    @Test("The event stream reports what changed, and nothing a listing already answers")
    func eventsReportChanges() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Watched")

        var events = VMLibraryEventReader(harness.core.events())
        // A fresh subscriber is told what happens from here, not replayed the
        // library it can already list.
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        let first = try #require(await events.next())
        guard case .statusChanged(let id, let name, let from, let to) = first else {
            Issue.record("expected a status change, got \(first)")
            return
        }
        #expect(id == instance.id)
        #expect(name == "Watched")
        #expect(from == "stopped")
        #expect(to == "running")
    }

    @Test("A session's end reports the agent status going absent")
    func eventsReportTheAgentStatusEndingWithTheSession() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Watched", phase: .running(sessionID: UUID()), guestOS: .macOS)
        instance.beginSessionContextForTesting().hasAgentTransport = true
        #expect(instance.agentPresentation?.status == .waiting)

        var events = VMLibraryEventReader(harness.core.events())
        instance.handleSessionEvent(.guestDidStop)
        #expect(instance.agentPresentation?.status == nil)

        while let event = await events.next() {
            guard case .agentStatusChanged(let id, _, let status) = event else { continue }
            #expect(id == instance.id)
            #expect(status == nil)
            return
        }
        Issue.record("the stream ended without an agent status change")
    }

    @Test("A Start failing into the error status, from rest or from the error status, reports one failure")
    func startFailingIntoErrorIsReportedOnce() async throws {
        for phase: VMLifecyclePhase in [.stopped, .failed(message: "An earlier failure")] {
            let harness = makeHarness()
            harness.virtualization.startError = VirtualizationError.noVirtualMachine
            let instance = makeInstance(in: harness, name: "Broken", phase: phase)
            let events = harness.core.events()

            _ = try? await harness.core.start(.id(instance.id), recovery: false, consent: .none)

            #expect(instance.status == .error)
            let failures = try await harness.wired.failureMessages(of: instance, on: events)
            #expect(failures.count == 1, "from \(phase)")
        }
    }

    @Test("A Suspend whose save fails reports one failure, worded as its caller was told")
    func suspendFailureIsReportedOnce() async throws {
        let harness = makeHarness()
        harness.virtualization.saveError = NSError(
            domain: "VZErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The virtual machine's state could not be saved."])
        let instance = makeInstance(in: harness, name: "Broken", phase: .running(sessionID: UUID()))
        let events = harness.core.events()

        let thrown = try await #require(throws: CommandError.self) {
            try await harness.core.suspend(.id(instance.id))
        }

        let failures = try await harness.wired.failureMessages(of: instance, on: events)
        #expect(failures == [thrown.message])
    }

    @Test("A clone whose copy fails reports the failure directly, then the arrival's removal")
    func cloneFailureReportsFailureThenRemoval() async throws {
        let harness = makeHarness()
        let cloneError = VMStorageError.bundleAlreadyExists(URL(filePath: "/tmp/occupied.kernova"))
        harness.storage.setCloneVMBundleError(cloneError)
        let instance = makeInstance(in: harness, name: "Source")
        var events = VMLibraryEventReader(harness.core.events())

        let summary = try await harness.core.clone(
            .id(instance.id), outcome: .newMachine, waitForOutcome: false)

        var failure: VMLibraryEvent?
        while let event = await events.next() {
            if case .failure = event {
                failure = event
                break
            }
        }
        guard case .failure(let id, _, let message)? = failure else {
            Issue.record("expected a failure event")
            return
        }
        #expect(id == summary.id)
        #expect(message == cloneError.localizedDescription)

        let removed = try #require(await events.next())
        guard case .removed(let removedID, _) = removed else {
            Issue.record("expected a removal, got \(removed)")
            return
        }
        #expect(removedID == summary.id)
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

    // MARK: - Unattended failures on the event stream

    /// An install-pending macOS VM: its start dispatches the setup and returns,
    /// so whatever happens next has no caller waiting on it.
    private func makeSetupPendingVM(in harness: Harness) -> VMInstance {
        makeInstance(in: harness, name: "Third", phase: .initialBoot, guestOS: .macOS) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
        }
    }

    @Test("A transient setup failure nobody awaited reaches the stream, carrying its message")
    func transientSetupFailureReachesTheEventStream() async throws {
        let install = MockMacOSInstallService()
        install.installError = makeInstallVMLimitExceededError()
        let harness = makeHarness(install: install)
        let instance = makeSetupPendingVM(in: harness)
        let events = harness.core.events()

        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        await instance.setupOperationTask?.value

        // Transient: the VM is back where a retry starts, its phase holding no
        // message.
        #expect(instance.status == .initialBoot)
        let messages = try await harness.wired.failureMessages(of: instance, on: events)
        #expect(messages.count == 1)
        // The sentence the alert gets, not the raw error — one failure, worded
        // once.
        #expect(messages.first == harness.failures.first?.message)
        #expect(harness.failures.first?.message.contains("at most two") == true)
    }

    @Test("A cancelled setup reports nothing — a cancel is somebody's decision, not a failure")
    func cancelledSetupReportsNothing() async throws {
        let install = MockMacOSInstallService()
        install.installError = CancellationError()
        let harness = makeHarness(install: install)
        let instance = makeSetupPendingVM(in: harness)
        let events = harness.core.events()

        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        await instance.setupOperationTask?.value

        #expect(instance.status == .initialBoot)
        #expect(harness.failures.isEmpty)
        let messages = try await harness.wired.failureMessages(of: instance, on: events)
        #expect(messages.isEmpty)
    }

    @Test("A transient failure on the boot chained after a setup reaches the stream too")
    func transientChainedBootFailureReachesTheEventStream() async throws {
        let harness = makeHarness()
        harness.virtualization.startError = makeVMLimitExceededError()
        let instance = makeSetupPendingVM(in: harness)
        let events = harness.core.events()

        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        // The chained boot runs after the setup operation has ended, so the
        // report is what says the work is over — and it lands after the event
        // does.
        try await harness.failureReported.wait { !harness.failures.isEmpty }

        // Transient again, and a boot rests where a plain start would.
        #expect(instance.status == .stopped)
        let reportedMessage = try #require(harness.failures.first?.message)
        #expect(reportedMessage.contains("at most two"))
        let messages = try await harness.wired.failureMessages(of: instance, on: events)
        #expect(messages == [reportedMessage])
    }

    // MARK: - The Guest Account

    private func makeAccountIntent() -> GuestAccountIntent {
        GuestAccountIntent(
            fullName: "Ada Lovelace", username: "ada", logsInAutomatically: true,
            enablesRemoteLogin: false)
    }

    /// An install-pending macOS VM, owing `intent` when one is given.
    private func makeInstallPendingVM(
        in harness: Harness, intent: GuestAccountIntent?
    ) -> VMInstance {
        makeInstance(
            in: harness, name: "Unattended VM", phase: .initialBoot, guestOS: .macOS
        ) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
            $0.pendingGuestAccount = intent
        }
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
    @available(macOS 27.0, *)
    @Test("The refusal carries the prompt naming the account")
    func theOwedAccountRefusalNamesTheAccount() async throws {
        let harness = makeHarness()
        let instance = makeInstallPendingVM(in: harness, intent: makeAccountIntent())

        let refusal = await #expect(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }

        let prompt = try #require(refusal?.guestAccountPrompt)
        #expect(prompt.username == "ada")
        #expect(prompt.fullName == "Ada Lovelace")
        #expect(prompt.vm.name == "Unattended VM")
        #expect(prompt.message.contains("ada"))
        #expect(try #require(refusal?.alertTitle).contains("Unattended VM"))
    }

    @available(macOS 27.0, *)
    // MARK: - What spends the account

    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @Test("A cold boot whose account retraction fails reports it with the start and keeps the password")
    func aColdBootWhoseRetractionFailsReportsItAndKeepsThePassword() async throws {
        let harness = makeHarness()
        let instance = makeBootableAccountVM(in: harness, intent: makeAccountIntent())
        try harness.core.provideGuestAccountPassword(
            .id(instance.id), password: "analytical-engine")
        harness.storage.setSaveConfigurationError(NSError(domain: "test", code: 1))

        let failure = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }

        #expect(harness.virtualization.lastStartRoute == .coldBoot)
        #expect(failure.message.contains("the boot that delivers its macOS account has run"))
        // The VM came up; only the record of the spent window is missing.
        #expect(instance.status == .running)
        #expect(instance.configuration.pendingGuestAccount == makeAccountIntent())
        #expect(harness.storage.bundles[instance.bundleURL]?.pendingGuestAccount == makeAccountIntent())
        #expect(harness.library.heldGuestAccountPassword(for: instance)?.value == "analytical-engine")
    }

    @available(macOS 27.0, *)
    /// The core acts on the route the boot *reported*, not on what the call asked
    /// for — which is the whole point of the boot answering: only the start that
    /// took the branch can say which branch it took.
    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @Test("An install that produced a pre-27 guest drops both halves of the account")
    func theInstallFloorDropEndsTheAccount() async throws {
        let install = MockMacOSInstallService()
        install.installedImage = .macOSRestoreImage(version: "26.5.2", build: "25F84")
        let harness = makeHarness(install: install)
        let instance = makeInstallPendingVM(in: harness, intent: makeAccountIntent())
        try harness.core.provideGuestAccountPassword(
            .id(instance.id), password: "analytical-engine")

        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        // The boot is a fresh admission the setup's outcome chains, so it is
        // waited for by its effect rather than by the setup's own task.
        try await waitForChange { instance.status == .running }

        // A persisted intent left behind would ask for an account this guest can
        // never create, and a held password would be a secret nothing can spend.
        #expect(instance.configuration.pendingGuestAccount == nil)
        #expect(harness.library.heldGuestAccountPassword(for: instance) == nil)
        // Dropped, never refused: the install itself landed.
        #expect(
            instance.configuration.installedImage
                == .macOSRestoreImage(version: "26.5.2", build: "25F84"))
        // The boot chained after the install carried no account, because there
        // was none left to carry.
        #expect(harness.virtualization.lastStartProvisioning == nil)
    }

    // MARK: - Restart

    @available(macOS 27.0, *)
    @Test("A restart of a VM still owing its account is refused while it is still running")
    func restartRefusesAnOwedAccount() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Unattended VM", phase: .running(sessionID: UUID()),
            guestOS: .macOS
        ) { $0.pendingGuestAccount = makeAccountIntent() }

        let refusal = await #expect(throws: CommandError.self) {
            try await harness.core.restart(.id(instance.id), disposition: .graceful, timeout: nil, consent: .none)
        }

        #expect(refusal?.guestAccountPrompt?.username == "ada")
        // Refused before the stop, so the guest is still up rather than parked
        // powered off half way through a restart.
        #expect(harness.virtualization.stopCallCount == 0)
        #expect(instance.status == .running)
    }

    @available(macOS 27.0, *)
    // MARK: - Guest setup

    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @Test("A skipped install runs, and its boot creates no account")
    func aSkippedInstallRunsAndAsksNothing() async throws {
        // An image above the provisioning floor, so the post-install drop for a
        // guest that cannot provision is not what this observes.
        let install = MockMacOSInstallService()
        install.installedImage = .macOSRestoreImage(version: "27.0", build: "27A100")
        let harness = makeHarness(install: install)
        let instance = makeInstallPendingVM(in: harness, intent: makeAccountIntent())
        try harness.core.skipGuestAccount(.id(instance.id))

        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        // The boot is a fresh admission the setup's outcome chains, so it is
        // waited for by its effect rather than by the setup's own task.
        try await waitForChange { instance.status == .running }

        #expect(harness.virtualization.startCallCount == 1)
        #expect(harness.virtualization.lastStartProvisioning == nil)
    }

    // MARK: - Create

    @available(macOS 27.0, *)
    @Test("A create holds the wizard's password for the start it chains")
    func createHoldsThePasswordForTheStartItChains() async throws {
        let harness = makeHarness()
        var configuration = VMConfiguration(
            name: "Unattended VM",
            guestOS: .macOS,
            bootMode: .macOS,
            cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        configuration.pendingGuestAccount = makeAccountIntent()

        let summary = try harness.core.create(
            configuration: configuration, diskSizeInGB: 64,
            startAfterCreate: true,
            guestAccountPassword: "analytical-engine")
        let arrival = try #require(harness.library.arrivals.first { $0.id == summary.id })
        let created = try #require(await arrival.settle())
        try await waitForChange { created.hasLiveSession }

        // The boot the create chained carried the wizard's password, so the user
        // is never asked again for what they just typed.
        #expect(harness.virtualization.lastStartProvisioning?.password == "analytical-engine")
        #expect(harness.virtualization.lastStartProvisioning?.username == "ada")
    }

    @available(macOS 27.0, *)
    @available(macOS 27.0, *)
    @Test("A create whose disk image failed reports the failure typed as a create")
    func failedCreateReportsThroughTheHookTyped() async throws {
        let diskImages = MockDiskImageService()
        diskImages.createDiskImageError = NSError(domain: "test", code: 1)
        let harness = makeHarness(diskImages: diskImages)

        // The write fails after the arrival is registered, so the sheet that
        // asked is long gone and the hook is all the failure has.
        _ = try harness.core.create(
            configuration: VMConfiguration(
                name: "Disk Fail VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize),
            diskSizeInGB: 64,
            startAfterCreate: false, guestAccountPassword: nil)
        try await harness.failureReported.wait { !harness.failures.isEmpty }

        #expect(harness.library.entries.isEmpty)
        guard case .operationFailed(let verb, _, _, _) = harness.failures.first else {
            Issue.record("Expected an operationFailed, got \(String(describing: harness.failures.first))")
            return
        }
        #expect(verb == .create)
    }

    @Test("A start failure that names its own heading carries it to the caller")
    func startFailureNamesItsOwnHeading() async throws {
        let harness = makeHarness()
        harness.virtualization.startError = NSError(
            domain: VirtualizationFailure.Framework.errorDomain,
            code: VirtualizationFailure.Framework.Code.virtualMachineLimitExceeded.rawValue)
        let instance = makeInstance(in: harness, name: "Capped")

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }

        // The heading a wire caller must get too — pinned there by
        // `operationFailureTitleCrossesTheWire`.
        #expect(error.alertTitle == "Couldn't Start \u{201C}Capped\u{201D}")
    }

    @Test("A rename that changes nothing is a no-op even mid-operation")
    func unchangedRenameIsNotRefused() throws {
        let harness = makeHarness()
        // Both inline-rename surfaces commit on end-editing whether or not the
        // text changed, so an unchanged commit landing here must not refuse.
        let instance = makeInstance(
            in: harness, name: "Steady", phase: .operating(.saving, from: .running(sessionID: UUID())))

        #expect(throws: Never.self) { try harness.core.rename(.id(instance.id), to: "Steady") }
        #expect(throws: Never.self) { try harness.core.rename(.id(instance.id), to: "   ") }
        #expect(instance.name == "Steady")
    }

    @Test("The invalid-state message names verbs the way a person does")
    func invalidStateMessageReadsAsCopy() throws {
        let harness = makeHarness()
        // Stopped: there is no display to open, and the state admits both a
        // start and a cold capture, so the sentence has something to list.
        let instance = makeInstance(in: harness, name: "Resting", phase: .stopped)

        let error = try #require(throws: CommandError.self) { try harness.core.open(.id(instance.id)) }

        // A wire name never reaches a user, and a read is admitted in every
        // state, so naming one says nothing.
        #expect(error.message.contains("Take Snapshot"))
        #expect(!error.message.contains("takeSnapshot"))
        #expect(!error.message.contains("ipAddress"))
    }

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
        try await first.value
        try await second.value

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

    @Test("A restart deadline expires on the shutdown half, leaving the guest unstarted")
    func restartRefusesWhenTheShutdownOutlastsItsDeadline() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let harness = makeHarness(virtualization: virtualization, clock: TestEngineClock())
        let session = UUID()
        let instance = makeInstance(
            in: harness, name: "Stubborn", phase: .running(sessionID: session))

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.restart(.id(instance.id), disposition: .graceful, timeout: 30, consent: .none)
        }

        guard case .timedOut(_, let verb, let seconds) = error else {
            Issue.record("Expected a timeout refusal, got \(error)")
            return
        }
        #expect(verb == .restart)
        #expect(seconds == 30)
        // The bring-up half never ran: a guest that would not shut down is not
        // restarted, and it is not terminated to make the restart happen.
        #expect(virtualization.startCallCount == 0)
        #expect(virtualization.forceStopCallCount == 0)
        #expect(instance.status == .running)

        // The boot was withdrawn with the expiry, so the guest going down
        // later brings nothing up.
        instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        #expect(instance.phase == .stopped)
        #expect(virtualization.startCallCount == 0)
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
        await harness.virtualization.waitUntilSuspended()
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
        let error = try await #require(throws: CommandError.self) { try await stop.value }
        guard case .timedOut(_, let verb, _) = error else {
            Issue.record("Expected a timeout refusal, got \(error)")
            return
        }
        #expect(verb == .stop)
        #expect(virtualization.forceStopCallCount == 0)
    }
}

extension CommandError {
    fileprivate var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    fileprivate var isInvalidState: Bool {
        if case .invalidState = self { return true }
        return false
    }
}

/// The core's batched event stream, read one event at a time.
///
/// A pass over the library delivers every change it found as one element, so a
/// case asserting on the order changes arrived in flattens the batches back
/// out.
private struct VMLibraryEventReader {
    private var batches: AsyncStream<[VMLibraryEvent]>.AsyncIterator
    private var pending: [VMLibraryEvent] = []

    init(_ stream: AsyncStream<[VMLibraryEvent]>) {
        batches = stream.makeAsyncIterator()
    }

    /// The next event, awaiting another batch once the current one is spent.
    mutating func next() async -> VMLibraryEvent? {
        while pending.isEmpty {
            guard let batch = await batches.next() else { return nil }
            pending = batch
        }
        return pending.removeFirst()
    }
}
