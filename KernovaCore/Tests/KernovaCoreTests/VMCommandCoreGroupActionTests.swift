import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The one group-action executor every door shares: which VMs each action
/// acts on, read from capabilities, and what it reports for the rest.
@Suite("VMCommandCore group actions", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreGroupActionTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMCommandCoreGroupActionTests")

    private typealias Harness = WiredCommandCore.Scripted<MockVirtualizationService>

    private func makeHarness(
        networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
    ) -> Harness {
        Harness(
            WiredCommandCore(
                virtualization: MockVirtualizationService(), networks: networks, organization: organization,
                preferences: preferences))
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String, guestOS: VMGuestOS = .linux, phase: VMLifecyclePhase = .stopped,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, library: harness.library, preferences: preferences,
            mutate: mutate)
    }

    /// One VM in each state a group action reads differently, in a folder
    /// holding them all in this order.
    private struct Library {
        let folder: VMGroupReference
        let stopped: VMInstance
        let running: VMInstance
        let paused: VMInstance
        let suspended: VMInstance
        let owesSetup: VMInstance
    }

    private func makeLibrary(in harness: Harness) throws -> Library {
        let stopped = makeInstance(in: harness, name: "Stopped")
        let running = makeInstance(in: harness, name: "Running", phase: .running(sessionID: UUID()))
        let paused = makeInstance(in: harness, name: "Paused", phase: .livePaused(sessionID: UUID()))
        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        let owesSetup = makeInstance(in: harness, name: "Fresh", guestOS: .macOS, phase: .initialBoot) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        let folder = try harness.library.organization.createFolder(
            named: "Lab", members: [stopped, running, paused, suspended, owesSetup].map(\.id))
        return Library(
            folder: VMGroupReference(.folder, named: folder.id.uuidString), stopped: stopped, running: running,
            paused: paused, suspended: suspended, owesSetup: owesSetup)
    }

    private func outcomes(_ report: VMGroupActionReport) -> [String: VMGroupActionOutcome] {
        Dictionary(uniqueKeysWithValues: report.results.map { ($0.vm.name, $0.outcome) })
    }

    // MARK: - Which VMs each action acts on

    @Test("Each action acts on the VMs its capabilities offer, and counts exactly those")
    func eachActionActsOnWhatItsCapabilitiesOffer() throws {
        let harness = makeHarness()
        let library = try makeLibrary(in: harness)
        let catalog = harness.library.capabilities

        func acts(_ action: VMGroupAction) -> [String] {
            [library.stopped, library.running, library.paused, library.suspended, library.owesSetup]
                .filter {
                    if case .acts = catalog.groupAction(action, on: $0) { true } else { false }
                }
                .map(\.name)
        }
        // Start brings up whatever can be: a boot, a restore, a hot resume —
        // but never a guest setup, and nothing already running.
        #expect(acts(.start) == ["Stopped", "Paused", "Suspended"])
        #expect(catalog.groupAction(.start, on: library.owesSetup) == .owesGuestSetup)
        #expect(catalog.groupAction(.start, on: library.stopped) == .acts(.start))
        #expect(catalog.groupAction(.start, on: library.suspended) == .acts(.resume))
        #expect(catalog.groupAction(.start, on: library.paused) == .acts(.resume))
        #expect(catalog.isAvailable(.start, on: library.owesSetup))
        // Suspend saves every live session, paused included.
        #expect(acts(.suspend) == ["Running", "Paused"])
        // Stop takes running guests only: a paused one's stop resumes it and a
        // suspended one's discards its saved state.
        #expect(acts(.stop) == ["Running"])
        #expect(catalog.isAvailable(.stop, on: library.paused))
        #expect(catalog.isAvailable(.discardSavedState, on: library.suspended))
        // Restart takes exactly what Stop takes: a paused guest is skipped
        // as Stop All skips it, and a suspended one has no guest to restart.
        #expect(acts(.restart) == acts(.stop))
        #expect(catalog.groupAction(.restart, on: library.running) == .acts(.restart))

        let counts = try harness.core.concernedCounts(in: library.folder)
        for action in VMGroupAction.allCases {
            #expect(counts[action] == acts(action).count)
        }
    }

    @Test("Start All starts or resumes what it counts, one per verb, and passes the rest over")
    func startAllStartsWhatItCounts() async throws {
        let harness = makeHarness()
        let library = try makeLibrary(in: harness)

        let report = try await harness.core.groupAction(.start, on: library.folder)

        #expect(report.results.map(\.vm.name) == ["Stopped", "Running", "Paused", "Suspended", "Fresh"])
        #expect(
            outcomes(report) == [
                "Stopped": .done(verb: .start), "Running": .passedOver(reason: .state),
                "Paused": .done(verb: .resume), "Suspended": .done(verb: .resume),
                "Fresh": .passedOver(reason: .guestSetup),
            ])
        #expect(report.undone.isEmpty)
        #expect(library.stopped.status == .running)
        #expect(library.paused.status == .running)
        #expect(library.suspended.status == .running)
        #expect(library.owesSetup.status == .initialBoot)
        // The summaries are read once the action is done with each VM.
        #expect(report.results.first?.vm.status == "running")
    }

    @Test("Suspend All saves running and paused guests; Stop All asks only the running one to shut down")
    func suspendAndStopAll() async throws {
        let harness = makeHarness()
        let library = try makeLibrary(in: harness)

        let stopped = try await harness.core.groupAction(.stop, on: library.folder)
        #expect(outcomes(stopped)["Running"] == .done(verb: .stop))
        #expect(stopped.results.filter { $0.outcome == .done(verb: .stop) }.count == 1)
        #expect(harness.virtualization.stopCallCount == 1)
        #expect(harness.virtualization.forceStopCallCount == 0)
        #expect(library.suspended.hasSaveFile)
        #expect(library.paused.status == .paused)

        let harness2 = makeHarness()
        let library2 = try makeLibrary(in: harness2)
        let suspended = try await harness2.core.groupAction(.suspend, on: library2.folder)
        #expect(
            outcomes(suspended) == [
                "Stopped": .passedOver(reason: .state), "Running": .done(verb: .suspend),
                "Paused": .done(verb: .suspend), "Suspended": .passedOver(reason: .state),
                "Fresh": .passedOver(reason: .state),
            ])
        #expect(harness2.virtualization.saveCallCount == 2)
    }

    @Test("Restart All takes every running guest at once: a held shutdown holds back only the report")
    func restartAllDoesNotWaitOnAHeldShutdown() async throws {
        let harness = makeHarness()
        // Each guest's power-off is delivered by hand.
        harness.virtualization.guestIgnoresShutdownRequest = true
        let heldSession = UUID()
        let otherSession = UUID()
        let held = makeInstance(in: harness, name: "Held", phase: .running(sessionID: heldSession))
        let other = makeInstance(in: harness, name: "Other", phase: .running(sessionID: otherSession))
        let folder = try harness.library.organization.createFolder(named: "Lab", members: [held.id, other.id])
        let reported = ReportBox()

        let restartAll = Task { @MainActor in
            reported.report = try await harness.core.groupAction(
                .restart, on: VMGroupReference(.folder, named: folder.id.uuidString))
        }
        // Both shutdowns asked for while neither guest has gone down.
        try await harness.virtualization.stopRequested.wait { harness.virtualization.stopCallCount == 2 }
        other.activity.deliverSessionEvent(.guestDidStop, from: otherSession)
        try await waitForChange {
            other.status == .running && other.activity.liveSessionID.map { $0 != otherSession } == true
        }
        #expect(held.activity.liveSessionID == heldSession)
        #expect(reported.report == nil)

        held.activity.deliverSessionEvent(.guestDidStop, from: heldSession)
        try await restartAll.value

        let report = try #require(reported.report)
        #expect(report.results.map(\.vm.name) == ["Held", "Other"])
        #expect(report.results.map(\.outcome) == [.done(verb: .restart), .done(verb: .restart)])
        #expect(held.status == .running)
        #expect(harness.virtualization.startCallCount == 2)
    }

    /// Where a test reads a group action's report once it has come back.
    @MainActor
    private final class ReportBox {
        var report: VMGroupActionReport?
    }

    // MARK: - What it reports

    @Test("A VM whose start asks to confirm a shared machine ID is skipped and listed; the rest start")
    func consentNeedingVMIsSkipped() async throws {
        let harness = makeHarness()
        preferences.allowsDuplicateMachineIDOverride = true
        let identity = Data([7, 7, 7])
        makeInstance(in: harness, name: "Live", phase: .running(sessionID: UUID())) {
            $0.genericMachineIdentifierData = identity
        }
        let twin = makeInstance(in: harness, name: "Twin") { $0.genericMachineIdentifierData = identity }
        let other = makeInstance(in: harness, name: "Other")
        try harness.library.organization.createFolder(named: "Pair", members: [twin.id, other.id])

        // Counted: the question is the start's, asked only when it commits.
        #expect(try harness.core.concernedCounts(in: VMGroupReference(.folder, named: "Pair"))[.start] == 2)
        let report = try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Pair"))

        guard case .needsAnswer(.start, let question) = report.results[0].outcome,
            case .confirmationRequired(let prompt) = question
        else {
            Issue.record("expected the twin skipped for a confirmation, got \(report.results[0].outcome)")
            return
        }
        #expect(prompt.kind == .startBesideSharedMachineIdentity)
        #expect(report.results[1].outcome == .done(verb: .start))
        #expect(twin.status == .stopped)
        #expect(other.status == .running)
        #expect(report.undone.map(\.vm.name) == ["Twin"])
        #expect(report.undoneTitle == "Couldn\u{2019}t Start Every VM in \u{201C}Pair\u{201D}")
        #expect(
            report.undoneMessage
                == "Skipped Twin: \(prompt.message) Start it on its own to answer.")
    }

    @Test("A smart group's arrival is passed over, never acted on")
    func arrivalIsPassedOver() async throws {
        let harness = makeHarness()
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(.importing, named: "Copying", gate: gate)
        makeInstance(in: harness, name: "Ready")
        try harness.library.organization.createSmartGroup(named: "Linux", filter: VMLibraryFilter(guestOSes: [.linux]))
        let group = VMGroupReference(.smartGroup, named: "Linux")

        #expect(try harness.core.concernedCounts(in: group)[.start] == 1)
        let report = try await harness.core.groupAction(.start, on: group)

        let arrived = try #require(report.results.first { $0.vm.id == arrival.id })
        #expect(arrived.outcome == .passedOver(reason: .state))
        #expect(arrived.vm.status == VMStatus.preparingWireName)
        #expect(report.results.first { $0.vm.name == "Ready" }?.outcome == .done(verb: .start))
        #expect(report.undone.isEmpty)
        gate.release()
        await arrival.settle()
    }

    // MARK: - Unattended bring-ups

    @Test("A group start refuses a guest setup at the commit, whatever was decided before it")
    func groupStartRefusesGuestSetupAtTheCommit() async throws {
        let harness = makeHarness()
        let fresh = makeInstance(in: harness, name: "Fresh", guestOS: .macOS, phase: .initialBoot) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }

        await #expect(throws: VMCommandCore.UnattendedGuestSetupRefusal.self) {
            try await harness.core.startNow(fresh, recovery: false, policy: .group).value()
        }
        #expect(fresh.status == .initialBoot)
        #expect(VMCommandCore.StartPolicy.group.presence == .unattended)
        #expect(VMCommandCore.StartPolicy.group.identity == .askable)
    }

    // MARK: - Failures on the event stream

    /// A restore that fails rests the VM back on its saved state, so its status
    /// carries nothing the stream could report it from.
    @Test("A member's failure that rests the VM where it began goes on the event stream, once")
    func memberFailureIsBroadcast() async throws {
        let harness = makeHarness()
        harness.virtualization.restoreError = VirtualizationError.restoreFailed(
            underlying: NSError(domain: "test", code: 1))
        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        try harness.library.organization.createFolder(named: "Lab", members: [suspended.id])
        let events = harness.core.events()

        let report = try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Lab"))

        guard case .failed = report.results.first?.outcome else {
            Issue.record("reported \(String(describing: report.results.first?.outcome))")
            return
        }
        #expect(suspended.status == .suspended)
        // Read up to a rename made after the action, so a second failure would
        // still be seen.
        let sentinel = "Read past the action"
        try harness.core.rename(.id(suspended.id), to: sentinel)
        var failures: [UUID] = []
        reading: for await batch in events {
            for event in batch {
                switch event {
                case .renamed(_, _, let to) where to == sentinel: break reading
                case .failure(let id, _, _): failures.append(id)
                default: continue
                }
            }
        }
        #expect(failures == [suspended.instanceID])
    }

    // MARK: - Launch pass

    /// A VM marked to start automatically.
    private func makeMarkedInstance(in harness: Harness, name: String) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: .stopped, guestOS: .linux, library: harness.library, preferences: preferences,
            hostState: VMHostState(startsAutomaticallyOnLaunch: true))
    }

    /// Unmarked on disk, so the turn reads the member and starts nothing — a
    /// start's identity check catches every other VM up on its own.
    @Test("The launch pass reads no VM outside the set it was handed")
    func launchPassReadsOnlyItsMembers() async {
        let harness = makeHarness()
        let member = makeMarkedInstance(in: harness, name: "Member")
        harness.storage.files.setHostState(VMHostState(), at: member.bundleURL)
        let other = makeInstance(in: harness, name: "Other")
        harness.storage.files.holdElsewhere(other.bundleURL)

        let results = await harness.core.startVMsMarkedToStartAutomatically([member.id])

        #expect(results.map(\.outcome) == [.passedOver(reason: .leftGroup)])
        #expect(!member.hostState.startsAutomaticallyOnLaunch)
        // Only a re-read probes for another copy's hold.
        #expect(!other.heldByAnotherCopy)
        harness.library.refreshFromOtherCopies(of: other)
        #expect(other.heldByAnotherCopy)
    }

    @Test("The launch pass reports a VM removed while its turn waited as gone")
    func launchMemberRemovedWhileItsTurnWaitedIsPassedOver() async throws {
        let harness = makeHarness()
        let held = makeMarkedInstance(in: harness, name: "Held")
        let deletion = GatedStep()
        let deleting = Task { @MainActor in
            try await held.activity.delete { _ in try await deletion.pass() }
        }
        try await deletion.waitUntilEntered()

        let pass = Task { @MainActor in await harness.core.startVMsMarkedToStartAutomatically([held.id]) }
        await drainMainQueue()
        #expect(held.activity.queuedFollowUpCountForTesting == 1)
        deletion.release()
        try await deleting.value
        let results = await pass.value

        #expect(results.map(\.outcome) == [.passedOver(reason: .removed)])
        #expect(harness.virtualization.startCallCount == 0)
    }

    /// The pass's turn names no request until it decides a start, so a start
    /// someone asked for behind it is never merged into a turn that passes
    /// the VM over.
    @Test("A start queued behind the launch pass's turn is decided on its own when the turn passes over")
    func startQueuedBehindALaunchTurnIsNotSwallowed() async throws {
        let harness = makeHarness()
        let held = makeMarkedInstance(in: harness, name: "Held")
        let copy = GatedStep()
        let copied = try held.activity.launchCopyOut(.stopped) { _ in
            try await copy.pass()
            return .rest(.asStarted, ())
        }
        try await copy.waitUntilEntered()

        let pass = Task { @MainActor in await harness.core.startVMsMarkedToStartAutomatically([held.id]) }
        await drainMainQueue()
        let start = harness.core.startFollowUp(held, identity: .unavailable)
        held.activity.follow(start)
        #expect(held.activity.queuedFollowUpCountForTesting == 2)
        try harness.core.setConfiguration(
            .id(held.id), assignments: [VMConfigurationKeyRegistry.autoStart.assigning(false)], consent: .none)

        copy.release()
        try await copied.value()
        let results = await pass.value
        try await start.outcome.value()

        #expect(results.map(\.outcome) == [.passedOver(reason: .leftGroup)])
        #expect(harness.virtualization.startCallCount == 1)
        #expect(held.status == .running)
    }

    // MARK: - Order and cancellation

    private typealias SuspendingHarness = WiredCommandCore.Scripted<SuspendingMockVirtualizationService>

    private func makeSuspendingHarness(
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
    ) -> SuspendingHarness {
        SuspendingHarness(
            WiredCommandCore(
                virtualization: SuspendingMockVirtualizationService(), organization: organization,
                preferences: preferences))
    }

    /// Two stopped VMs in a folder, in that order.
    private func makePair(in harness: SuspendingHarness) throws -> (VMInstance, VMInstance) {
        let first = RegisteredVMInstanceFixture.register(
            name: "First", phase: .stopped, guestOS: .linux, library: harness.library, preferences: preferences)
        let second = RegisteredVMInstanceFixture.register(
            name: "Second", phase: .stopped, guestOS: .linux, library: harness.library, preferences: preferences)
        try harness.library.organization.createFolder(named: "Pair", members: [first.id, second.id])
        return (first, second)
    }

    @Test("A cancel lets the VM in hand finish and reports every later one untouched")
    func cancelStopsBetweenVMs() async throws {
        let harness = makeSuspendingHarness()
        let (first, second) = try makePair(in: harness)

        let running = Task { @MainActor in
            try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Pair"))
        }
        await harness.virtualization.waitUntilSuspended()
        running.cancel()
        harness.virtualization.resumeSuspended()
        let report = try await running.value

        #expect(report.results.map(\.outcome) == [.done(verb: .start), .passedOver(reason: .cancelled)])
        #expect(harness.virtualization.startCallCount == 1)
        #expect(first.status == .running)
        #expect(second.status == .stopped)
        #expect(report.undone.isEmpty)
    }

    /// Runs Start All on the pair, doing `midRun` while the first VM's
    /// bring-up is under way — before the second VM's turn.
    private func startPair(
        in harness: SuspendingHarness, group: VMGroupReference = VMGroupReference(.folder, named: "Pair"),
        midRun: () async throws -> Void
    ) async throws -> VMGroupActionReport {
        let running = Task { @MainActor in
            try await harness.core.groupAction(.start, on: group)
        }
        await harness.virtualization.waitUntilSuspended()
        try await midRun()
        harness.virtualization.shouldSuspendOnStart = false
        harness.virtualization.resumeSuspended()
        return try await running.value
    }

    // MARK: - Membership during the run

    @Test("A member deleted before its turn is passed over as gone, named as this copy last knew it")
    func memberDeletedBeforeItsTurnIsPassedOver() async throws {
        let harness = makeSuspendingHarness()
        let (first, second) = try makePair(in: harness)

        let report = try await startPair(in: harness) {
            try await harness.core.delete(.id(second.id), permanently: true, alsoRemoving: [], consent: .all)
        }

        #expect(report.results.map(\.outcome) == [.done(verb: .start), .passedOver(reason: .removed)])
        #expect(report.results[1].vm.name == "Second")
        #expect(report.results[1].vm.status == "stopped")
        #expect(first.status == .running)
        #expect(report.undone.isEmpty)
    }

    @Test("A member taken out of the group before its turn is passed over, not acted on")
    func memberTakenOutOfTheGroupBeforeItsTurnIsPassedOver() async throws {
        let harness = makeSuspendingHarness()
        let (first, second) = try makePair(in: harness)
        let folder = try #require(harness.library.organization.state.listed?.folder(named: "Pair"))

        let report = try await startPair(in: harness) {
            try harness.library.remove(second.id, fromFolder: folder.id)
        }

        #expect(report.results.map(\.outcome) == [.done(verb: .start), .passedOver(reason: .leftGroup)])
        #expect(first.status == .running)
        #expect(second.status == .stopped)
        #expect(report.undone.isEmpty)
    }

    // MARK: - Another copy's hold

    /// A harness whose `Networks.json` and one member's host state are
    /// unreadable — what a refresh of the library or of a bundle would
    /// report through the config check — and a count of each time it asks for
    /// the check, with the folder "Pair" of `free` and `held`.
    private func makeUnreadableHarness() throws -> (Harness, free: VMInstance, held: VMInstance, checks: () -> Int) {
        let networksURL = scratch.url.appendingPathComponent("Networks.json")
        let harness = makeHarness(networks: VMNetworkDirectory(fileURL: networksURL))
        let free = makeInstance(in: harness, name: "Free")
        let held = makeInstance(in: harness, name: "Held")
        try harness.library.organization.createFolder(named: "Pair", members: [free.id, held.id])
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: networksURL)
        harness.storage.files.setUnreadable(
            true, relativePath: VMBundleLayout.hostStateRelativePath, at: free.bundleURL)
        var checks = 0
        harness.library.onUnreadableFilesFound = { checks += 1 }
        return (harness, free, held, { checks })
    }

    @Test("The counts read the groups as this copy holds them, reloading no file")
    func countsReloadNoOrganization() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let organizationURL = scratch.url.appendingPathComponent("Organization.json")
        let harness = makeHarness(organization: VMOrganizationDirectory(fileURL: organizationURL))
        let stopped = makeInstance(in: harness, name: "Stopped")
        try harness.library.organization.createFolder(named: "Lab", members: [stopped.id])
        // What a reload would find, and refuse the counts for.
        try Data("not json".utf8).write(to: organizationURL)

        #expect(try harness.core.concernedCounts(in: VMGroupReference(.folder, named: "Lab"))[.start] == 1)
        #expect(harness.library.organization.state.listed != nil)
    }

    @Test("The action catches the library up first, leaving what it finds unreadable to the next report")
    func actionCatchesUpWithoutRaisingTheCheck() async throws {
        let (harness, _, held, checks) = try makeUnreadableHarness()
        harness.storage.files.holdElsewhere(held.bundleURL)

        let report = try await harness.core.groupAction(.stop, on: VMGroupReference(.folder, named: "Pair"))

        #expect(report.results.map(\.outcome) == [.passedOver(reason: .state), .passedOver(reason: .state)])
        #expect(report.results[1].vm.heldByAnotherCopy)
        #expect(checks() == 0)
        harness.library.reportNewlyUnreadable()
        #expect(checks() == 1)
    }

    @Test("A smart group's members are the ones it holds once the library has caught up")
    func smartGroupResolvesFromTheCaughtUpLibrary() async throws {
        let harness = makeHarness()
        makeInstance(in: harness, name: "Free")
        let held = makeInstance(in: harness, name: "Held")
        try harness.library.organization.createSmartGroup(named: "Idle", filter: VMLibraryFilter(states: [.stopped]))
        harness.storage.files.holdElsewhere(held.bundleURL)

        let report = try await harness.core.groupAction(.start, on: VMGroupReference(.smartGroup, named: "Idle"))

        #expect(report.results.map(\.vm.name) == ["Free"])
        #expect(report.results.map(\.outcome) == [.done(verb: .start)])
    }

    @Test("A smart group's members are fixed at the start: one another copy takes is held, not gone from the group")
    func smartGroupMemberTakenMidRunIsHeld() async throws {
        let harness = makeSuspendingHarness()
        let (_, second) = try makePair(in: harness)
        try harness.library.organization.createSmartGroup(named: "Idle", filter: VMLibraryFilter(states: [.stopped]))

        let report = try await startPair(in: harness, group: VMGroupReference(.smartGroup, named: "Idle")) {
            harness.storage.files.holdElsewhere(second.bundleURL)
        }

        #expect(report.results.map(\.vm.name) == ["First", "Second"])
        #expect(report.results.map(\.outcome) == [.done(verb: .start), .passedOver(reason: .state)])
        #expect(report.results[1].vm.heldByAnotherCopy)
    }

    // MARK: - Error mapping

    @Test("A question is a VM to answer for; the quit and another copy's hold are nobody's failure; the rest fail")
    func refusalsMapToOutcomes() {
        let vm = VMSummary(id: UUID(), name: "VM", status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false)
        let confirmation = CommandError.confirmationRequired(
            ConfirmationPrompt(
                kind: .startBesideSharedMachineIdentity, title: "T", message: "M", confirmTitle: "C",
                dismissTitle: "D"))
        let account = CommandError.guestAccountPasswordRequired(
            GuestAccountPrompt(vm: vm, username: "me", fullName: "Me", message: "M"))
        for question in [confirmation, account] {
            #expect(
                VMCommandCore.outcome(of: question, takenBy: .resume)
                    == .needsAnswer(verb: .resume, question: question.dto))
        }
        #expect(
            VMCommandCore.outcome(of: .terminating, takenBy: .start)
                == .passedOver(reason: .refused(error: .terminating)))
        // A step refusal names a step of its own, which a group action takes
        // for nobody.
        let step = CommandError.stepRequired(
            StepRequirement(
                message: "M",
                routes: [
                    StepRoute(title: "Own", steps: [.setConfiguration(vm: vm, assignments: [])], ending: .refusedVerb)
                ]))
        #expect(VMCommandCore.outcome(of: step, takenBy: .resume) == .failed(error: step.dto))
        let failed = CommandError.operationFailed(verb: .start, message: "No.")
        #expect(VMCommandCore.outcome(of: failed, takenBy: .start) == .failed(error: failed.dto))
        #expect(
            VMCommandCore.outcome(of: .busy(vm: vm, operation: "saving"), takenBy: .suspend)
                == .failed(error: .busy(vm: vm, operation: "saving")))
        #expect(VMCommandCore.outcome(of: .heldByAnotherCopy(vm: vm), takenBy: .start) == .passedOver(reason: .state))
    }
}
