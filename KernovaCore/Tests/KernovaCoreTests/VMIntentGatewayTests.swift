import AppIntents
import CoreSpotlight
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The App Intents front door: what Shortcuts and Spotlight see, how it
/// waits for the library, and how it addresses VMs.
///
/// Driven through the gateway rather than through `VMEntityQuery`, which holds
/// no logic of its own — it forwards, and the `@Dependency` it forwards through
/// resolves only inside a live intent session.
@Suite("VM Intent Gateway Tests", .caseScoped)
@MainActor
struct VMIntentGatewayTests {
    private func makeSummary(name: String) -> VMSummary {
        VMSummary(id: UUID(), name: name, status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false)
    }

    /// A gateway whose library read has already landed, over a real core.
    private func makeGateway(
        over harness: WiredCommandCore,
        record: VMIndexRecord = makeTestIndexRecord(),
        index: MockVMEntityIndex = MockVMEntityIndex()
    ) -> VMIntentGateway {
        VMIntentGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}), index: index,
            record: record)
    }

    /// A readiness that parks until `release` yields, telling `entered` once
    /// a caller is waiting on it.
    private func makeParkedReadiness(
        entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>
    ) -> LibraryReadiness {
        LibraryReadiness(awaitReady: {
            entered.yield(())
            for await _ in release { break }
        })
    }

    // MARK: - Entity

    @Test("An entity carries the whole info read, and reads its status back in words")
    func entityDescribesItsSummary() throws {
        let info = VMIntentFixtures.info(name: "Sonoma", status: "running", snapshotCount: 3)
        let entity = VMEntity(info)

        #expect(entity.id == info.id)
        #expect(entity.name == "Sonoma")
        #expect(entity.status == "running")
        #expect(entity.guestOS == info.guestOS)
        #expect(entity.cpuCount == info.cpuCount)
        #expect(entity.memoryBytes == Int(info.memoryBytes))
        #expect(entity.networkMode == info.networkMode)
        #expect(entity.macAddress == info.macAddress)
        #expect(entity.ipAddress == info.ipAddress.address)
        #expect(entity.agentStatus == info.agentStatus)
        #expect(VMEntity(VMIntentFixtures.info(agentStatus: nil)).agentStatus == nil)
        #expect(entity.hasSavedState == info.hasSavedState)
        #expect(entity.isEphemeral == info.isEphemeral)
        #expect(entity.snapshotCount == 3)
        #expect(entity.bundlePath == info.bundlePath)
        #expect(String(localized: entity.displayRepresentation.title) == "Sonoma")
        let subtitle = try #require(entity.displayRepresentation.subtitle)
        #expect(String(localized: subtitle) == "Running")
    }

    @Test("An entity tells a suspended VM from a paused one in its State and subtitle")
    func entityTellsSuspendedFromPaused() throws {
        let suspended = VMEntity(VMIntentFixtures.info(status: "suspended"))
        let paused = VMEntity(VMIntentFixtures.info(status: "paused"))

        #expect(suspended.status == "suspended")
        #expect(paused.status == "paused")
        #expect(String(localized: try #require(suspended.displayRepresentation.subtitle)) == "Suspended")
        #expect(String(localized: try #require(paused.displayRepresentation.subtitle)) == "Paused")
    }

    @Test("An entity for a VM another copy holds is subtitled as held, not by its status")
    func entityNamesAHeldVM() throws {
        let entity = VMEntity(VMIntentFixtures.info(status: "stopped", heldByAnotherCopy: true))

        #expect(entity.status == "stopped")
        #expect(
            String(localized: try #require(entity.displayRepresentation.subtitle))
                == VMStatus.heldByAnotherCopyDisplayName)
    }

    @Test("Get State answers a suspended VM's wire status and says it is suspended")
    func getStateAnswersSuspended() {
        let answer = GetVMStateIntent.answer(for: VMIntentFixtures.info(name: "Tahoe", status: "suspended"))

        #expect(answer.value == "suspended")
        #expect(answer.dialog == "Tahoe is suspended.")
    }

    @Test("Get State says a VM another copy holds is in use there")
    func getStateNamesAHeldVM() {
        let answer = GetVMStateIntent.answer(
            for: VMIntentFixtures.info(name: "Tahoe", status: "stopped", heldByAnotherCopy: true))

        #expect(answer.value == "stopped")
        #expect(answer.dialog == "Tahoe is in use by another copy of Kernova.")
    }

    @Test("A VM still copying into place reads back as preparing, which is no VMStatus")
    func entityNamesThePreparingWireStatus() {
        #expect(VMStatus(rawValue: VMStatus.preparingWireName) == nil)
        #expect(
            VMStatus.displayName(forWireName: VMStatus.preparingWireName, heldByAnotherCopy: false)
                == "Preparing")
        #expect(VMStatus.displayName(forWireName: "initialBoot", heldByAnotherCopy: false) == "Initial Boot")
    }

    @Test("The Spotlight record carries the name and the guest, and no runtime status")
    func entityIndexesItsNameAndGuest() throws {
        let mac = VMIntentFixtures.info(name: "Sonoma", status: "running", guestOS: "macOS")
        let linux = VMIntentFixtures.info(name: "Ubuntu", guestOS: "linux")

        let attributes = VMEntity(mac).attributeSet
        #expect(attributes.displayName == "Sonoma")
        #expect(attributes.contentDescription == "macOS virtual machine")
        // A status change must cost no re-index, so none is written.
        let described = try #require(attributes.contentDescription)
        #expect(!described.contains("running"))
        #expect(VMEntity(linux).attributeSet.contentDescription == "Linux virtual machine")
    }

    // MARK: - Stop Method

    @Test("Every stop disposition is offered, named, and maps back to itself")
    func stopMethodsMirrorEveryDisposition() {
        for disposition in StopDisposition.allCases {
            let method = VMStopMethod(disposition)
            #expect(method.disposition == disposition)
            #expect(VMStopMethod.caseDisplayRepresentations[method] != nil)
        }
    }

    // MARK: - Lookup

    @Test("Resolving by identifier answers only the VMs asked for")
    func lookupFiltersByIdentifier() async throws {
        let harness = WiredCommandCore()
        harness.register(name: "First")
        let second = harness.register(name: "Second")

        let gateway = makeGateway(over: harness)
        let resolved = await gateway.vms(withIDs: [second.id, UUID()])

        #expect(resolved.map(\.id) == [second.id])
        #expect(resolved.map(\.name) == ["Second"])
    }

    @Test("A typed name matches case-insensitively, and every VM that answers to it")
    func lookupMatchesNamesCaseInsensitively() async throws {
        let harness = WiredCommandCore()
        harness.register(name: "Sonoma")
        harness.register(name: "Sonoma")
        harness.register(name: "Ubuntu")

        let gateway = makeGateway(over: harness)

        let twins = await gateway.vms(matching: "sonoma")
        let byPrefix = await gateway.vms(matching: "UBUN")
        let none = await gateway.vms(matching: "nothing")

        #expect(twins.count == 2)
        #expect(byPrefix.map(\.name) == ["Ubuntu"])
        #expect(none.isEmpty)
        // The sidebar search's own predicate: the trimmed term, diacritics
        // ignored.
        #expect(await gateway.vms(matching: "  sónoma ").count == 2)
    }

    @Test("The whole library is enumerable, so Shortcuts offers a picker")
    func lookupEnumeratesTheLibrary() async throws {
        let harness = WiredCommandCore()
        let first = harness.register(name: "First")
        let second = harness.register(name: "Second", phase: .running(sessionID: UUID()))

        let all = await makeGateway(over: harness).vms()

        #expect(all.map(\.id) == [first.id, second.id])
        #expect(all.map(\.name) == ["First", "Second"])
        // Each row is the VM's whole read.
        #expect(all.map(\.status) == ["stopped", "running"])
    }

    // MARK: - Filtering and Sorting

    /// The library the property query narrows, in library order.
    private var mixedLibrary: [VMEntity] {
        [
            VMEntity(VMIntentFixtures.info(name: "Ubuntu", status: "running", snapshotCount: 2)),
            VMEntity(VMIntentFixtures.info(name: "sonoma", status: "stopped", snapshotCount: 5)),
            VMEntity(VMIntentFixtures.info(name: "Tahoe", status: "paused", snapshotCount: 0)),
        ]
    }

    @Test("Naming no filter asks for the library, under either mode")
    func narrowingWithoutComparatorsKeepsEverything() {
        for mode in [EntityQueryComparatorMode.and, .or] {
            let kept = VMEntityQuery.narrowed(
                mixedLibrary, matching: [], mode: mode, sortedBy: [], limit: nil)

            #expect(kept.map(\.name) == ["Ubuntu", "sonoma", "Tahoe"])
        }
    }

    @Test("Every filter has to match under and; any one is enough under or")
    func narrowingHonoursTheComparatorMode() {
        let running: VMEntityQuery.ComparatorMappingType = { $0.status == "running" }
        let manySnapshots: VMEntityQuery.ComparatorMappingType = { $0.snapshotCount >= 2 }

        let all = VMEntityQuery.narrowed(
            mixedLibrary, matching: [running, manySnapshots], mode: .and, sortedBy: [], limit: nil)
        let any = VMEntityQuery.narrowed(
            mixedLibrary, matching: [running, manySnapshots], mode: .or, sortedBy: [], limit: nil)

        #expect(all.map(\.name) == ["Ubuntu"])
        #expect(any.map(\.name) == ["Ubuntu", "sonoma"])
    }

    @Test("A limit truncates what the filter kept")
    func narrowingHonoursTheLimit() {
        let kept = VMEntityQuery.narrowed(
            mixedLibrary, matching: [], mode: .and, sortedBy: [], limit: 2)

        #expect(kept.map(\.name) == ["Ubuntu", "sonoma"])
    }

    @Test("Each offered sort orders both ways; anything else leaves library order")
    func sortingOrdersByEveryOfferedProperty() {
        let byName = VMEntityQuery.sorted(mixedLibrary, by: \VMEntity.$name, ascending: true)
        let byNameDescending = VMEntityQuery.sorted(
            mixedLibrary, by: \VMEntity.$name, ascending: false)
        let byStatus = VMEntityQuery.sorted(mixedLibrary, by: \VMEntity.$status, ascending: true)
        let bySnapshots = VMEntityQuery.sorted(
            mixedLibrary, by: \VMEntity.$snapshotCount, ascending: true)
        let byNothingOffered = VMEntityQuery.sorted(
            mixedLibrary, by: \VMEntity.$bundlePath, ascending: true)

        // Case-insensitive: a typed name is not matched by ASCII order.
        #expect(byName.map(\.name) == ["sonoma", "Tahoe", "Ubuntu"])
        #expect(byNameDescending.map(\.name) == ["Ubuntu", "Tahoe", "sonoma"])
        #expect(byStatus.map(\.status) == ["paused", "running", "stopped"])
        #expect(bySnapshots.map(\.snapshotCount) == [0, 2, 5])
        #expect(byNothingOffered.map(\.name) == ["Ubuntu", "sonoma", "Tahoe"])
    }

    // MARK: - Readiness

    @Test("No read reaches the core until the app's first library read has landed")
    func readsWaitForTheLibraryRead() async throws {
        let harness = WiredCommandCore()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let index = MockVMEntityIndex()
        let gateway = VMIntentGateway(
            commands: harness.core,
            readiness: makeParkedReadiness(entered: entered.continuation, release: release.stream),
            index: index, record: makeTestIndexRecord())

        let read = Task { await gateway.vms() }
        for await _ in entered.stream { break }
        // Registered while the read is parked: a read that had already
        // reached the core would answer an empty library.
        let late = harness.register(name: "Late")
        #expect(index.operations.isEmpty)

        release.continuation.yield(())
        release.continuation.finish()

        #expect(await read.value.map(\.id) == [late.id])
        try await index.awaitOperations(Self.syncedOperations)
        #expect(index.operations == [.index([late.id])])
    }

    // MARK: - Verb Dispatch

    @Test("Every verb addresses its VM by identifier, never by name")
    func verbsAddressByIdentifier() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization)
        // Name twins: any verb addressed by name would be refused as ambiguous.
        // macOS guests, since only they boot into Recovery.
        let vm = harness.register(name: "Twin", guestOS: .macOS)
        let twin = harness.register(name: "Twin", guestOS: .macOS)
        let id = vm.id
        let gateway = makeGateway(over: harness)

        try await gateway.start(id, recovery: true, consent: .none)
        #expect(vm.status == .running)
        #expect(virtualization.lastStartBootIntoRecovery)

        try await gateway.stop(id, disposition: .force, consent: .all)
        #expect(vm.status == .stopped)
        #expect(virtualization.forceStopCallCount == 1)
        #expect(virtualization.stopCallCount == 0)

        try await gateway.start(id, recovery: false, consent: .none)
        #expect(vm.status == .running)
        #expect(!virtualization.lastStartBootIntoRecovery)

        try await gateway.open(id)
        #expect(harness.surfacedDisplays == [id])
        // A running VM's reveal is its display.
        try await gateway.reveal(id)
        #expect(harness.surfacedDisplays == [id, id])
        #expect(harness.revealedInLibrary.isEmpty)
        #expect(try await gateway.ipAddress(of: id) == nil)

        let snapshot = try await gateway.takeSnapshot(id, name: "Before", notes: "a note")
        #expect(snapshot.name == "Before")
        #expect(snapshot.notes == "a note")
        #expect(vm.snapshotManifest.ordered.map(\.id) == [snapshot.id])

        try await gateway.pause(id)
        #expect(vm.status == .paused)
        try await gateway.resume(id, consent: .none)
        #expect(vm.status == .running)
        try await gateway.suspend(id)
        #expect(vm.status == .suspended)

        #expect(twin.status == .stopped)
        #expect(twin.snapshotManifest.ordered.isEmpty)
        #expect(virtualization.startCallCount == 2)
    }

    /// An intent's caller is not sitting there waiting on a deadline: the
    /// restart waits out the guest's power-off however long it takes. Only a
    /// guest slower than the request shows it, since a deadline is armed only
    /// once the request is sent and the guest is still up.
    @Test("A restart waits out the guest's power-off with no deadline")
    func restartWaitsWithoutADeadline() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let clock = GatedEngineClock()
        let harness = WiredCommandCore(virtualization: virtualization, clock: clock)
        let session = UUID()
        let vm = harness.register(name: "Rebooting", phase: .running(sessionID: session))
        let gateway = makeGateway(over: harness)

        let restart = Task { try await gateway.restart(vm.id, consent: .none) }
        try await virtualization.stopRequested.wait { virtualization.stopCallCount == 1 }
        // The turn that sent the request is the one that arms any deadline, and
        // a deadline's sleep is queued behind it.
        await drainMainQueue()
        #expect(clock.requestedSeconds.isEmpty)
        #expect(vm.liveSessionID == session)

        vm.deliverSessionEvent(.guestDidStop, from: session)
        try await restart.value

        #expect(vm.status == .running)
        #expect(vm.liveSessionID != session)
    }

    @Test("The quit verb reaches the core, addressing no VM")
    func quitReachesTheCore() async throws {
        let harness = WiredCommandCore()
        let vm = harness.register(name: "Wired", phase: .running(sessionID: UUID()))

        await makeGateway(over: harness).quit()
        try await harness.quitRequested.wait { harness.quitRequests == 1 }

        #expect(harness.quitRequests == 1)
        #expect(vm.status == .running)
    }

    // MARK: - Search

    @Test("A search term reaches the library's search once the library has landed, addressing no VM")
    func searchFillsTheLibrarySearchOnceReady() async {
        let harness = WiredCommandCore()
        harness.register(name: "Sonoma")
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var terms: [String] = []
        let gateway = VMIntentGateway(
            commands: harness.core,
            readiness: makeParkedReadiness(entered: entered.continuation, release: release.stream),
            index: MockVMEntityIndex(), record: makeTestIndexRecord(),
            showSearchResults: { terms.append($0) })

        let search = Task { await gateway.showSearchResults(for: "sonoma") }
        for await _ in entered.stream { break }
        #expect(terms.isEmpty)

        release.continuation.yield(())
        release.continuation.finish()
        await search.value

        #expect(terms == ["sonoma"])
        #expect(harness.revealedInLibrary.isEmpty)
        #expect(harness.surfacedDisplays.isEmpty)
    }

    @Test("Spotlight's Open on an indexed VM has an intent to run")
    func openIntentIsDeclared() {
        // Compiling is the assertion: Spotlight opens an indexed entity by
        // running the app's `OpenIntent` for that entity type, and finds none
        // when no intent declares the conformance.
        let intent: any OpenIntent = OpenVMIntent()
        #expect(intent is OpenVMIntent)
    }

    @Test("A refusal from the core reaches the caller unchanged")
    func refusalsPassThrough() async throws {
        let harness = WiredCommandCore()
        harness.register(name: "Wired")
        let missing = UUID()

        await #expect(throws: CommandError.notFound(.id(missing))) {
            try await makeGateway(over: harness).start(missing, recovery: false, consent: .none)
        }
    }

    // MARK: - Consent

    /// A paused VM's force stop offers no alternative: its graceful stop is
    /// refused until it resumes.
    @Test("A consent refusal is asked once and the verb re-issued with it")
    func consentRetriesTheVerb() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization)
        let vm = harness.register(name: "Paused", phase: .livePaused(sessionID: UUID()))
        let expected = VMCommandCore.forceStopPrompt(vm)
        let gateway = makeGateway(over: harness)
        var asked: [ConfirmationPrompt] = []

        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { consent in
            try await gateway.stop(vm.id, disposition: .force, consent: consent)
        }

        #expect(expected.alternatives.isEmpty)
        #expect(asked == [expected])
        #expect(virtualization.forceStopCallCount == 1)
        #expect(vm.status == .stopped)
    }

    /// A running VM's force stop carries the gentler "Shut Down" alternative
    /// (`VMCommandCore.forceStopPrompt`), so it is the shape that proves the
    /// retry is not gated on a prompt having no alternatives — keying on that
    /// would leave Force Stop permanently unreachable for a hung guest.
    @Test("Force-stopping a running VM confirms, alternative or not")
    func consentRetriesAForceStopThatOffersShutDown() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization)
        let vm = harness.register(name: "Hung", phase: .running(sessionID: UUID()))
        let gateway = makeGateway(over: harness)
        var asked: [ConfirmationPrompt] = []

        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { consent in
            try await gateway.stop(vm.id, disposition: .force, consent: consent)
        }

        #expect(asked.map(\.kind) == [.forceStop])
        #expect(asked.first?.alternatives == [ConfirmationAlternative(title: "Shut Down", disposition: .graceful)])
        // Forced both times: the alternative is never taken in its place.
        #expect(virtualization.forceStopCallCount == 1)
        #expect(virtualization.stopCallCount == 0)
        #expect(vm.status == .stopped)
    }

    @Test("A step refusal is never answered by confirming")
    func consentLeavesAStepRefusalStanding() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization)
        let vm = harness.register(name: "Alpha", phase: .livePaused(sessionID: UUID()))
        let gateway = makeGateway(over: harness)
        var asked = 0

        await #expect(throws: CommandError.stepRequired(harness.core.pausedStopRefusal(vm))) {
            try await VMConsentPolicy.run(prompting: { _ in asked += 1 }) { consent in
                try await gateway.stop(vm.id, disposition: .graceful, consent: consent)
            }
        }

        #expect(asked == 0)
        #expect(virtualization.stopCallCount == 0)
        #expect(virtualization.forceStopCallCount == 0)
        #expect(vm.status == .paused)
    }

    @Test("A failure that is not a consent refusal is never turned into a question")
    func consentLeavesOtherFailuresAlone() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization)
        let vm = harness.register(
            name: "Busy", phase: .operating(.saving, from: .running(sessionID: UUID())))
        let gateway = makeGateway(over: harness)
        var asked = 0

        let failure = try await #require(throws: CommandError.self) {
            try await VMConsentPolicy.run(prompting: { _ in asked += 1 }) { consent in
                try await gateway.stop(vm.id, disposition: .graceful, consent: consent)
            }
        }

        #expect(failure.isBusy)
        #expect(asked == 0)
        #expect(virtualization.stopCallCount == 0)
    }

    // MARK: - Error Surfacing

    @Test("A refusal reaches Shortcuts carrying the sentence every other surface shows")
    func refusalsCarryTheirMessage() {
        let vm = makeSummary(name: "Busy")
        let failures: [CommandError] = [
            .notFound(.id(vm.id)),
            .invalidState(vm: vm, current: .running, allowed: [.stop, .pause]),
            .busy(vm: vm, operation: "starting"),
        ]

        for failure in failures {
            #expect(String(localized: failure.localizedStringResource) == failure.message)
        }
    }

    // MARK: - Spotlight

    /// The writes the readiness sync makes over an index holding nothing stale,
    /// which every batch assertion counts from: one whole-library write.
    private static let syncedOperations = 1

    /// Reads `events` up to the batch reporting `vm` running.
    ///
    /// Every stream the core hands out is fed the same batches in the same
    /// order, so the gateway's own subscription holds that batch too, ahead of
    /// anything changed after this returns.
    private func readUntilRunning(_ vm: VMInstance, on events: AsyncStream<[VMLibraryEvent]>) async {
        for await batch in events {
            for event in batch {
                if case .statusChanged(let id, _, _, let to) = event, id == vm.id, to == "running" { return }
            }
        }
    }

    @Test("Readiness writes the whole library, emptying nothing")
    func readinessSyncsTheWholeLibrary() async throws {
        let harness = WiredCommandCore()
        let first = harness.register(name: "First")
        let second = harness.register(name: "Second")
        let index = MockVMEntityIndex()
        let record = makeTestIndexRecord()
        let gateway = makeGateway(over: harness, record: record, index: index)

        try await index.awaitOperations(Self.syncedOperations)

        #expect(index.operations == [.index([first.id, second.id])])
        #expect(record.indexedVMIDs == [first.id, second.id])
        withExtendedLifetime(gateway) {}
    }

    @Test("Readiness drops only the VMs it recorded indexing that the library no longer holds")
    func readinessPrunesWhatLeftTheLibrary() async throws {
        let harness = WiredCommandCore()
        let kept = harness.register(name: "Kept")
        let gone = UUID()
        let record = makeTestIndexRecord([gone, kept.id])
        let index = MockVMEntityIndex()
        let gateway = makeGateway(over: harness, record: record, index: index)

        // The write lands before the prune, so a process ending between them
        // leaves the library findable rather than nothing at all.
        try await index.awaitOperations(2)

        #expect(index.operations == [.index([kept.id]), .remove([gone])])
        #expect(record.indexedVMIDs == [kept.id])
        withExtendedLifetime(gateway) {}
    }

    @Test("A refused whole-library write keeps the recorded VMs, and the next batch re-attempts it")
    func refusedSyncIsRetriedOnTheNextBatch() async throws {
        let harness = WiredCommandCore()
        let vm = harness.register(name: "Wired")
        let stale = UUID()
        let record = makeTestIndexRecord([stale])
        let index = MockVMEntityIndex()
        index.indexError = CocoaError(.fileWriteUnknown)
        let gateway = makeGateway(over: harness, record: record, index: index)

        try await index.awaitOperations(Self.syncedOperations)
        #expect(index.operations == [.index([vm.id])])
        #expect(record.indexedVMIDs == [stale])

        index.indexError = nil
        // A status change shows neither surface anything new, and is still the
        // moment the refused write is re-attempted.
        try await harness.core.start(.id(vm.id), recovery: false, consent: .none)

        try await index.awaitOperations(Self.syncedOperations + 1)
        #expect(index.operations == [.index([vm.id]), .index([vm.id])])
        #expect(record.indexedVMIDs == [stale, vm.id])
        withExtendedLifetime(gateway) {}
    }

    @Test("A refused removal is retried on the next batch, and forgotten only once it lands")
    func refusedRemovalIsRetriedOnTheNextBatch() async throws {
        let harness = WiredCommandCore()
        let gone = harness.register(name: "Gone")
        let kept = harness.register(name: "Kept")
        let record = makeTestIndexRecord()
        let index = MockVMEntityIndex()
        let gateway = makeGateway(over: harness, record: record, index: index)

        try await index.awaitOperations(Self.syncedOperations)
        #expect(index.operations == [.index([gone.id, kept.id])])
        #expect(record.indexedVMIDs == [gone.id, kept.id])

        index.removeError = CocoaError(.fileWriteUnknown)
        harness.storage.files.removeBundle(at: gone.bundleURL)
        harness.library.reconcileWithDisk()

        try await index.awaitOperations(Self.syncedOperations + 1)
        #expect(index.operations == [.index([gone.id, kept.id]), .remove([gone.id])])
        #expect(record.indexedVMIDs == [gone.id, kept.id])

        index.removeError = nil
        try await harness.core.start(.id(kept.id), recovery: false, consent: .none)

        try await index.awaitOperations(Self.syncedOperations + 2)
        #expect(
            index.operations == [
                .index([gone.id, kept.id]), .remove([gone.id]), .remove([gone.id]),
            ])
        #expect(record.indexedVMIDs == [kept.id])
        withExtendedLifetime(gateway) {}
    }

    @Test("A batch of additions is written once, however many VMs arrived")
    func aBatchOfAdditionsIsWrittenOnce() async throws {
        let harness = WiredCommandCore()
        let index = MockVMEntityIndex()
        let gateway = makeGateway(over: harness, index: index)

        try await index.awaitOperations(Self.syncedOperations)

        // The launch case: one pass over the library reports every VM it holds.
        let arriving = (1...6).map { harness.register(name: "VM \($0)") }

        try await index.awaitOperations(Self.syncedOperations + 1)
        #expect(index.operations == [.index([]), .index(arriving.map(\.id))])
        withExtendedLifetime(gateway) {}
    }

    @Test("A batch's removals are dropped and its renames re-indexed; status changes touch neither")
    func indexFollowsTheLibrary() async throws {
        let harness = WiredCommandCore()
        let gone = harness.register(name: "Gone")
        let kept = harness.register(name: "Kept")
        let index = MockVMEntityIndex()
        let gateway = makeGateway(over: harness, index: index)
        let events = harness.core.events()

        try await index.awaitOperations(Self.syncedOperations)

        // Ordered through one stream: the status-only batch is drained before
        // the batch whose writes are awaited, so the count proves it wrote
        // nothing.
        try await harness.core.start(.id(kept.id), recovery: false, consent: .none)
        await readUntilRunning(kept, on: events)
        // One turn, so one batch: the removal and the rename.
        harness.storage.files.removeBundle(at: gone.bundleURL)
        harness.library.reconcileWithDisk()
        try harness.core.rename(.id(kept.id), to: "Renamed")

        try await index.awaitOperations(Self.syncedOperations + 2)
        #expect(
            index.operations == [.index([gone.id, kept.id]), .remove([gone.id]), .index([kept.id])])
        withExtendedLifetime(gateway) {}
    }

    @Test("A Spotlight refusal is swallowed, leaving the batch behind it indexed")
    func indexRefusalsAreSwallowed() async throws {
        let harness = WiredCommandCore()
        let vm = harness.register(name: "Wired")
        let index = MockVMEntityIndex()
        index.indexError = CocoaError(.fileWriteUnknown)
        let gateway = makeGateway(over: harness, index: index)

        try await index.awaitOperations(Self.syncedOperations)
        try harness.core.rename(.id(vm.id), to: "Renamed")
        try await index.awaitOperations(Self.syncedOperations + 1)

        index.indexError = nil
        let added = harness.register(name: "Added")

        try await index.awaitOperations(Self.syncedOperations + 2)
        // The retried VM and the new one, written together in library order.
        #expect(
            index.operations == [.index([vm.id]), .index([vm.id]), .index([vm.id, added.id])])
        withExtendedLifetime(gateway) {}
    }
}
