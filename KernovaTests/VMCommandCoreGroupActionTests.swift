import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The one group-action executor every door shares: which VMs each action
/// acts on, read from capabilities, and what it reports for the rest.
@Suite("VMCommandCore group actions", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreGroupActionTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMCommandCoreGroupActionTests")

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let virtualization: MockVirtualizationService
        let storage: MockVMStorageService
    }

    private func makeHarness(
        networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
    ) -> Harness {
        let storage = MockVMStorageService()
        let fileSystem = MockFileSystem()
        let virtualization = MockVirtualizationService()
        let lifecycle = makeTestLifecycle(virtualization: virtualization, fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: MockVMBundleMachineFiles(files: storage.files), lifecycle: lifecycle,
            fileSystem: fileSystem, preferences: preferences, networks: networks, organization: organization)
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem, preferences: preferences)
        return Harness(core: core, library: library, virtualization: virtualization, storage: storage)
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

    @Test("Failures land in one report: the macOS guest cap fails one VM and the others still start")
    func macOSGuestLimitIsAPerVMFailure() async throws {
        let harness = makeHarness()
        let first = makeInstance(in: harness, name: "First", guestOS: .macOS)
        let second = makeInstance(in: harness, name: "Second", guestOS: .macOS)
        let third = makeInstance(in: harness, name: "Third", guestOS: .macOS)
        let linux = makeInstance(in: harness, name: "Linux")
        harness.virtualization.startErrors[third.id] = makeVMLimitExceededError()
        try harness.library.organization.createFolder(
            named: "Macs", members: [first, second, third, linux].map(\.id))

        let report = try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Macs"))

        #expect(report.results.map(\.outcome.isUndone) == [false, false, true, false])
        guard case .failed(let error) = report.results[2].outcome else {
            Issue.record("expected the third to fail, got \(report.results[2].outcome)")
            return
        }
        #expect(error.message.contains("macOS allows at most two macOS virtual machines to run at once."))
        #expect([first, second, linux].allSatisfy { $0.status == .running })
        #expect(third.status == .stopped)
        #expect(report.undone.map(\.vm.name) == ["Third"])
        #expect(report.undoneMessage == "Couldn\u{2019}t start Third: \(error.message)")
    }

    @Test("A VM busy with other work is passed over with the refusal its own verb would give")
    func busyVMIsPassedOverWithItsRefusal() async throws {
        let harness = makeHarness()
        let busy = makeInstance(
            in: harness, name: "Busy", phase: .operating(.saving, from: .running(sessionID: UUID())))
        try harness.library.organization.createFolder(named: "One", members: [busy.id])

        let report = try await harness.core.groupAction(.suspend, on: VMGroupReference(.folder, named: "One"))

        guard case .passedOver(.refused(let error)) = report.results[0].outcome,
            case .busy(_, let operation) = error
        else {
            Issue.record("expected a busy refusal, got \(report.results[0].outcome)")
            return
        }
        #expect(operation == "suspending")
        #expect(report.undone.isEmpty)
    }

    @Test("A group the library does not list is refused before any VM is acted on")
    func unknownGroupIsRefused() async throws {
        let harness = makeHarness()
        makeInstance(in: harness, name: "Stopped")

        await #expect(throws: CommandError.itemNotFoundOnHost(item: "folder named \u{201C}Nope\u{201D}")) {
            try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Nope"))
        }
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A group action selects nothing and readies only what a start from any door readies")
    func groupActionMovesNoSelection() async throws {
        let harness = makeHarness()
        let a = makeInstance(in: harness, name: "A")
        let b = makeInstance(in: harness, name: "B")
        try harness.library.organization.createFolder(named: "Both", members: [a.id, b.id])
        var surfaced: [String] = []
        var revealed: [UUID] = []
        harness.core.surfaceDisplay = { surfaced.append($0.name) }
        harness.core.revealInLibrary = { revealed.append($0) }
        let selected = harness.library.selectedID

        _ = try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Both"))

        #expect(a.status == .running && b.status == .running)
        #expect(harness.library.selectedID == selected)
        #expect(surfaced.isEmpty)
        #expect(revealed.isEmpty)
    }

    // MARK: - Unattended bring-ups

    @Test("Every bring-up a group action takes is readied as unattended, a detached display's included")
    func groupBringUpsAreReadiedUnattended() async throws {
        let harness = makeHarness()
        let popOut = RegisteredVMInstanceFixture.register(
            name: "Pop Out", phase: .stopped, guestOS: .linux, library: harness.library, preferences: preferences,
            hostState: VMHostState(displayPreference: .fullscreen))
        let paused = RegisteredVMInstanceFixture.register(
            name: "Paused", phase: .livePaused(sessionID: UUID()), guestOS: .linux, library: harness.library,
            preferences: preferences, hostState: VMHostState(displayPreference: .popOut))
        try harness.library.organization.createFolder(named: "Lab", members: [popOut.id, paused.id])
        var readied: [String: VMBringUpPresence] = [:]
        harness.core.readyDisplay = { readied[$0.name] = $1 }

        _ = try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Lab"))

        #expect(readied == ["Pop Out": .unattended, "Paused": .unattended])

        // The same VM started on its own is attended.
        try await harness.core.stop(.id(popOut.id), disposition: .force, consent: .all, timeout: nil)
        readied = [:]
        try await harness.core.start(.id(popOut.id), recovery: false, consent: .none)
        #expect(readied == ["Pop Out": .attended])
    }

    @Test("A group start refuses a guest setup at the commit, whatever was decided before it")
    func groupStartRefusesGuestSetupAtTheCommit() async throws {
        let harness = makeHarness()
        let fresh = makeInstance(in: harness, name: "Fresh", guestOS: .macOS, phase: .initialBoot) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }

        await #expect(throws: VMCommandCore.UnattendedGuestSetupRefusal.self) {
            try await harness.core.start(fresh, recovery: false, policy: .group, macAddressRemedy: nil)
        }
        #expect(fresh.status == .initialBoot)
        #expect(VMCommandCore.StartPolicy.group.presence == .unattended)
        #expect(VMCommandCore.StartPolicy.group.identity == .askable)
    }

    // MARK: - Order and cancellation

    private struct SuspendingHarness {
        let core: VMCommandCore
        let library: VMLibrary
        let virtualization: SuspendingMockVirtualizationService
        let storage: MockVMStorageService
    }

    private func makeSuspendingHarness(
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
    ) -> SuspendingHarness {
        let storage = MockVMStorageService()
        let fileSystem = MockFileSystem()
        let virtualization = SuspendingMockVirtualizationService()
        let lifecycle = makeTestLifecycle(virtualization: virtualization, fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: MockVMBundleMachineFiles(files: storage.files), lifecycle: lifecycle,
            fileSystem: fileSystem, preferences: preferences, organization: organization)
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem, preferences: preferences)
        return SuspendingHarness(core: core, library: library, virtualization: virtualization, storage: storage)
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

    @Test("VMs are acted on one after another: the second start waits for the first bring-up to end")
    func actsOneAfterAnother() async throws {
        let harness = makeSuspendingHarness()
        let (first, second) = try makePair(in: harness)

        let running = Task { @MainActor in
            try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Pair"))
        }
        await harness.virtualization.waitUntilSuspended()

        #expect(harness.virtualization.startCallCount == 1)
        #expect(second.status == .stopped)
        harness.virtualization.shouldSuspendOnStart = false
        harness.virtualization.resumeSuspended()
        let report = try await running.value

        #expect(harness.virtualization.startCallCount == 2)
        #expect(report.results.map(\.outcome) == [.done(verb: .start), .done(verb: .start)])
        #expect(first.status == .running && second.status == .running)
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

    @Test("A member that arrives as a VM before its turn is acted on")
    func arrivalThatLandsBeforeItsTurnIsActedOn() async throws {
        let harness = makeSuspendingHarness()
        let first = RegisteredVMInstanceFixture.register(
            name: "First", phase: .stopped, guestOS: .linux, library: harness.library, preferences: preferences)
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(.importing, named: "Arriving", gate: gate)
        try harness.library.organization.createFolder(named: "Pair", members: [first.id, arrival.id])

        let report = try await startPair(in: harness) {
            gate.release()
            await arrival.settle()
        }

        #expect(report.results.map(\.vm.name) == ["First", "Arriving"])
        #expect(report.results.map(\.outcome) == [.done(verb: .start), .done(verb: .start)])
        #expect(report.results[1].vm.status == "running")
        #expect(report.undone.isEmpty)
    }

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

    @Test("The counts read only what this copy holds, touching no disk; the library's catch-up moves them")
    func countsTouchNoDisk() throws {
        let (harness, _, held, checks) = try makeUnreadableHarness()
        harness.storage.files.holdElsewhere(held.bundleURL)
        let reads = harness.storage.files.readCount(of: VMBundleLayout.configRelativePath)
        let pair = VMGroupReference(.folder, named: "Pair")

        // No run lock probed, no bundle re-read, no config check asked for.
        #expect(try harness.core.concernedCounts(in: pair)[.start] == 2)
        #expect(!held.heldByAnotherCopy)
        #expect(harness.storage.files.readCount(of: VMBundleLayout.configRelativePath) == reads)
        #expect(checks() == 0)

        harness.library.refreshFromOtherCopies()
        #expect(try harness.core.concernedCounts(in: pair)[.start] == 1)
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

    @Test("Each turn re-reads its VM's bundle: a guest setup another copy finished is seen")
    func turnReReadsItsVM() async throws {
        let harness = makeSuspendingHarness()
        let first = RegisteredVMInstanceFixture.register(
            name: "First", phase: .stopped, guestOS: .linux, library: harness.library, preferences: preferences)
        let fresh = RegisteredVMInstanceFixture.register(
            name: "Fresh", phase: .initialBoot, guestOS: .macOS, library: harness.library, preferences: preferences
        ) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        try harness.library.organization.createFolder(named: "Pair", members: [first.id, fresh.id])

        let report = try await startPair(in: harness) {
            var finished = fresh.configuration
            finished.installContext = nil
            harness.storage.files.setConfiguration(finished, at: fresh.bundleURL)
        }

        #expect(report.results.map(\.outcome) == [.done(verb: .start), .done(verb: .start)])
        #expect(fresh.status == .running)
    }

    @Test("A turn reloads no library file")
    func turnReloadsNoLibraryFile() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let organizationURL = scratch.url.appendingPathComponent("Organization.json")
        let harness = makeSuspendingHarness(organization: VMOrganizationDirectory(fileURL: organizationURL))
        let (_, second) = try makePair(in: harness)

        let report = try await startPair(in: harness) {
            try Data("not json".utf8).write(to: organizationURL)
        }

        #expect(report.results.map(\.outcome) == [.done(verb: .start), .done(verb: .start)])
        #expect(second.status == .running)
        #expect(harness.library.organization.state.listed != nil)
    }

    @Test("A VM another copy starts before its turn is passed over, not failed")
    func vmHeldBeforeItsTurnIsPassedOver() async throws {
        let harness = makeSuspendingHarness()
        let (first, second) = try makePair(in: harness)

        let report = try await startPair(in: harness) {
            harness.storage.files.holdElsewhere(second.bundleURL)
        }

        #expect(report.results.map(\.outcome) == [.done(verb: .start), .passedOver(reason: .state)])
        #expect(report.results[1].vm.heldByAnotherCopy)
        #expect(report.undone.isEmpty)
        #expect(first.status == .running)
        #expect(second.status == .stopped)
    }

    @Test("A VM another copy lets go of before its turn is acted on")
    func vmReleasedBeforeItsTurnIsActedOn() async throws {
        let harness = makeSuspendingHarness()
        let (_, second) = try makePair(in: harness)
        harness.storage.files.holdElsewhere(second.bundleURL)

        let report = try await startPair(in: harness) {
            harness.storage.files.releaseElsewhere(second.bundleURL)
        }

        #expect(report.results.map(\.outcome) == [.done(verb: .start), .done(verb: .start)])
        #expect(second.status == .running)
    }

    @Test("A VM another copy takes between its turn's read and its commit is passed over as held, not failed")
    func vmTakenAtTheCommitIsPassedOver() async throws {
        let harness = makeHarness()
        let taken = makeInstance(in: harness, name: "Taken")
        try harness.library.organization.createFolder(named: "One", members: [taken.id])
        harness.storage.files.holdElsewhereAfterProbes(taken.bundleURL)

        let report = try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "One"))

        #expect(report.results.map(\.outcome) == [.passedOver(reason: .state)])
        #expect(report.results[0].vm.heldByAnotherCopy)
        #expect(report.undone.isEmpty)
        #expect(harness.virtualization.startCallCount == 0)
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
        let remedy = CommandError.macAddressRemedyRequired(
            MACAddressRemedyPrompt(
                vm: vm, other: vm, verb: .resume, title: "T", message: "M",
                offers: [MACAddressRemedyOffer(remedy: .ownNetwork, title: "Own", isDestructive: false)],
                dismissTitle: "D"))

        for question in [confirmation, account, remedy] {
            #expect(
                VMCommandCore.outcome(of: question, takenBy: .resume)
                    == .needsAnswer(verb: .resume, question: question.dto))
        }
        #expect(
            VMCommandCore.outcome(of: .terminating, takenBy: .start)
                == .passedOver(reason: .refused(error: .terminating)))
        let failed = CommandError.operationFailed(verb: .start, message: "No.")
        #expect(VMCommandCore.outcome(of: failed, takenBy: .start) == .failed(error: failed.dto))
        #expect(
            VMCommandCore.outcome(of: .busy(vm: vm, operation: "saving"), takenBy: .suspend)
                == .failed(error: .busy(vm: vm, operation: "saving")))
        #expect(VMCommandCore.outcome(of: .heldByAnotherCopy(vm: vm), takenBy: .start) == .passedOver(reason: .state))
    }
}
