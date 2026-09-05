import AppIntents
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The App Intents front door: what Shortcuts and Spotlight see, how it
/// waits for the library, and how it addresses VMs.
///
/// Driven through the gateway rather than through `VMEntityQuery`, which holds
/// no logic of its own — it forwards, and the `@Dependency` it forwards through
/// resolves only inside a live intent session.
@Suite("VM Intent Gateway Tests")
@MainActor
struct VMIntentGatewayTests {
    private static let stoppedID = UUID()

    private func makeSummary(
        name: String = "Wired", status: String = "stopped", id: UUID = UUID()
    ) -> VMSummary {
        VMSummary(id: id, name: name, status: status)
    }

    /// A gateway whose library read has already landed, over a seeded mock.
    private func makeGateway(
        _ commands: MockVMCommanding,
        defaults: UserDefaults,
        index: MockVMEntityIndex = MockVMEntityIndex()
    ) -> VMIntentGateway {
        VMIntentGateway(commands: commands, awaitReady: {}, index: index, defaults: defaults)
    }

    /// An isolated defaults store named for one test.
    ///
    /// The gateway records there which VMs it has written to the index, and
    /// prunes the index against what it reads back, so two tests sharing one
    /// store would prune against each other's VMs.
    private func makeStore(_ test: String) -> UserDefaults {
        makeEphemeralDefaults(suiteName: "test.kernova.intentgateway.\(test)")
    }

    /// The VMs `defaults` records as written to the index.
    private func indexedIDs(in defaults: UserDefaults) -> Set<UUID> {
        Set(
            (defaults.stringArray(forKey: VMIntentGateway.indexedVMIDsKey) ?? [])
                .compactMap(UUID.init(uuidString:)))
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
        #expect(entity.diskSizeInGB == info.diskSizeInGB)
        #expect(entity.networkMode == info.networkMode)
        #expect(entity.macAddress == info.macAddress)
        #expect(entity.ipAddress == info.ipAddress)
        #expect(entity.agentStatus == info.agentStatus)
        #expect(entity.hasSavedState == info.hasSavedState)
        #expect(entity.isEphemeral == info.isEphemeral)
        #expect(entity.snapshotCount == 3)
        #expect(entity.bundlePath == info.bundlePath)
        #expect(String(localized: entity.displayRepresentation.title) == "Sonoma")
        let subtitle = try #require(entity.displayRepresentation.subtitle)
        #expect(String(localized: subtitle) == "Running")
    }

    @Test("A VM still copying into place reads back as preparing, which is no VMStatus")
    func entityNamesThePreparingWireStatus() {
        #expect(VMStatus(rawValue: VMCommandCore.preparingWireStatus) == nil)
        #expect(VMEntity.statusDisplayName(VMCommandCore.preparingWireStatus) == "Preparing")
        #expect(VMEntity.statusDisplayName("initialBoot") == "Initial Boot")
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
        let commands = MockVMCommanding()
        let first = makeSummary(name: "First")
        let second = makeSummary(name: "Second")
        commands.library = [first, second]

        let gateway = makeGateway(commands, defaults: makeStore("lookup-ids"))
        let resolved = await gateway.vms(withIDs: [second.id])

        #expect(resolved.map(\.name) == ["Second"])
    }

    @Test("A typed name matches case-insensitively, and every VM that answers to it")
    func lookupMatchesNamesCaseInsensitively() async throws {
        let commands = MockVMCommanding()
        commands.library = [
            makeSummary(name: "Sonoma"), makeSummary(name: "Sonoma"), makeSummary(name: "Ubuntu"),
        ]

        let gateway = makeGateway(commands, defaults: makeStore("lookup-names"))

        let twins = await gateway.vms(matching: "sonoma")
        let byPrefix = await gateway.vms(matching: "UBUN")
        let none = await gateway.vms(matching: "nothing")

        #expect(twins.count == 2)
        #expect(byPrefix.map(\.name) == ["Ubuntu"])
        #expect(none.isEmpty)
    }

    @Test("The whole library is enumerable, so Shortcuts offers a picker")
    func lookupEnumeratesTheLibrary() async throws {
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "First"), makeSummary(name: "Second")]

        let all = await makeGateway(commands, defaults: makeStore("lookup-all")).vms()

        #expect(all.map(\.name) == ["First", "Second"])
    }

    // MARK: - Filtering and Sorting

    /// The library the property query narrows, in the order the sidebar shows.
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
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Late")]
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let index = MockVMEntityIndex()
        let gateway = VMIntentGateway(
            commands: commands,
            awaitReady: {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            },
            index: index, defaults: makeStore("readiness-wait"))

        let read = Task { await gateway.vms() }
        for await _ in entered.stream { break }
        #expect(commands.listCallCount == 0)

        release.continuation.yield(())
        release.continuation.finish()

        #expect(await read.value.map(\.name) == ["Late"])
        // Two: this read, and the whole-library read the readiness sync makes.
        try await index.gate.wait { index.operations.count == Self.syncedOperations }
        #expect(commands.listCallCount == 2)
    }

    @Test("The library read is awaited once, however many intents pile onto it")
    func readinessIsMemoized() async throws {
        let commands = MockVMCommanding()
        let awaits = Counter()
        let gateway = VMIntentGateway(
            commands: commands, awaitReady: { await awaits.increment() },
            index: MockVMEntityIndex(), defaults: makeStore("readiness-memoized"))

        _ = await gateway.vms()
        _ = await gateway.vms()
        try await gateway.start(UUID(), recovery: false)

        #expect(await awaits.value == 1)
    }

    // MARK: - Verb Dispatch

    @Test("Every verb addresses its VM by identifier, never by name")
    func verbsAddressByIdentifier() async throws {
        let commands = MockVMCommanding()
        let id = Self.stoppedID
        commands.library = [makeSummary(name: "Twin", id: id)]
        let gateway = makeGateway(commands, defaults: makeStore("verbs"))

        try await gateway.start(id, recovery: true)
        try await gateway.stop(id, disposition: .force, confirmed: true)
        try await gateway.pause(id)
        try await gateway.resume(id)
        try await gateway.suspend(id)
        try await gateway.restart(id)
        try await gateway.open(id)
        try await gateway.reveal(id)
        _ = try await gateway.takeSnapshot(id, name: "Before", notes: "a note")
        _ = try await gateway.ipAddress(of: id)

        #expect(commands.startCalls.map(\.selector) == [.id(id)])
        #expect(commands.startCalls.map(\.recovery) == [true])
        #expect(commands.stopCalls.map(\.selector) == [.id(id)])
        #expect(commands.stopCalls.map(\.disposition) == [.force])
        #expect(commands.pauseSelectors == [.id(id)])
        #expect(commands.resumeCalls.map(\.selector) == [.id(id)])
        #expect(commands.suspendSelectors == [.id(id)])
        #expect(commands.restartSelectors == [.id(id)])
        #expect(commands.openSelectors == [.id(id)])
        #expect(commands.revealSelectors == [.id(id)])
        #expect(commands.ipAddressSelectors == [.id(id)])
        #expect(commands.takeSnapshotCalls.map(\.selector) == [.id(id)])
        #expect(commands.takeSnapshotCalls.map(\.name) == ["Before"])
        #expect(commands.takeSnapshotCalls.map(\.notes) == ["a note"])
    }

    // MARK: - Search

    /// A gateway that records every request for the library window, for the
    /// search that has no VM to reveal.
    private func makeSearchGateway(
        _ commands: MockVMCommanding, defaults: UserDefaults,
        surfaced: @escaping @MainActor () -> Void
    ) -> VMIntentGateway {
        VMIntentGateway(
            commands: commands, awaitReady: {}, index: MockVMEntityIndex(),
            defaults: defaults, surfaceLibrary: surfaced)
    }

    @Test("A search term reveals the first VM whose name carries it")
    func searchRevealsTheFirstMatch() async throws {
        let commands = MockVMCommanding()
        let ubuntu = makeSummary(name: "Ubuntu")
        let sonoma = makeSummary(name: "Sonoma Test")
        commands.library = [ubuntu, sonoma]
        var libraryRequests = 0
        let gateway = makeSearchGateway(
            commands, defaults: makeStore("searchmatch"), surfaced: { libraryRequests += 1 })

        // Typed the way a person types it: neither the case nor the whole name.
        try await gateway.revealSearchResult(matching: "sonoma")

        #expect(commands.revealSelectors == [.id(sonoma.id)])
        #expect(libraryRequests == 0)
    }

    @Test("A search term no VM answers to brings the library forward instead")
    func searchWithNoMatchSurfacesTheLibrary() async throws {
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Ubuntu")]
        var libraryRequests = 0
        let gateway = makeSearchGateway(
            commands, defaults: makeStore("searchmiss"), surfaced: { libraryRequests += 1 })

        try await gateway.revealSearchResult(matching: "Sequoia")

        #expect(commands.revealSelectors.isEmpty)
        #expect(libraryRequests == 1)
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
        let commands = MockVMCommanding()
        commands.startError = CommandError.busy(vm: makeSummary(), operation: "starting")
        let gateway = makeGateway(commands, defaults: makeStore("refusals"))

        await #expect(throws: CommandError.self) {
            try await gateway.start(UUID(), recovery: false)
        }
    }

    // MARK: - Consent

    @Test("A consent refusal is asked once and the verb re-issued with it")
    func consentRetriesTheVerb() async throws {
        let commands = MockVMCommanding()
        let id = UUID()
        commands.stopConsentPrompt = ConfirmationPrompt(
            kind: .forceStop,
            title: "Force Stop Virtual Machine",
            message: "Unsaved guest state is lost.",
            confirmTitle: "Force Stop",
            dismissTitle: "Cancel")
        let gateway = makeGateway(commands, defaults: makeStore("consent-retry"))
        var asked: [ConfirmationPrompt] = []

        try await VMIntentConsent.run(prompting: { asked.append($0) }) { confirmed in
            try await gateway.stop(id, disposition: .force, confirmed: confirmed)
        }

        #expect(asked.map(\.kind) == [.forceStop])
        #expect(commands.stopCalls.map(\.confirmed) == [false, true])
    }

    /// A running VM's force stop carries the gentler "Shut Down" alternative
    /// (`VMCommandCore.forceStopPrompt`), so it is the shape that proves the
    /// retry is not gated on a prompt having no alternatives — keying on that
    /// would leave Force Stop permanently unreachable for a hung guest.
    @Test("Force-stopping a running VM confirms, alternative or not")
    func consentRetriesAForceStopThatOffersShutDown() async throws {
        let commands = MockVMCommanding()
        let id = UUID()
        commands.stopConsentPrompt = ConfirmationPrompt(
            kind: .forceStop,
            title: "Force Stop Virtual Machine",
            message: "\u{201C}Hung\u{201D} will be immediately terminated.",
            confirmTitle: "Force Stop",
            dismissTitle: "Cancel",
            alternatives: [ConfirmationAlternative(title: "Shut Down", disposition: .graceful)])
        let gateway = makeGateway(commands, defaults: makeStore("consent-force-stop"))
        var asked = 0

        try await VMIntentConsent.run(prompting: { _ in asked += 1 }) { confirmed in
            try await gateway.stop(id, disposition: .force, confirmed: confirmed)
        }

        #expect(asked == 1)
        #expect(commands.stopCalls.map(\.confirmed) == [false, true])
        #expect(commands.stopCalls.map(\.disposition) == [.force, .force])
    }

    @Test("Only a prompt that confirms to something else is refused for the user")
    func onlyStopPausedIsRefused() {
        for kind in ConfirmationKind.allCases {
            let prompt = ConfirmationPrompt(
                kind: kind, title: "T", message: "M", confirmTitle: "C", dismissTitle: "D")
            #expect(VMIntentConsent.isAnsweredByConfirming(prompt) == (kind != .stopPaused))
        }
    }

    @Test("A prompt that confirms to a different verb is refused rather than answered")
    func consentRefusesToChooseAmongAlternatives() async throws {
        let commands = MockVMCommanding()
        commands.stopConsentPrompt = ConfirmationPrompt(
            kind: .stopPaused,
            title: "Shut Down Paused Virtual Machine",
            message: "Resume it first, or force stop it.",
            confirmTitle: "Resume and Shut Down",
            dismissTitle: "Cancel",
            alternatives: [ConfirmationAlternative(title: "Force Stop", disposition: .force)])
        let gateway = makeGateway(commands, defaults: makeStore("consent-alternatives"))
        var asked = 0

        await #expect(throws: CommandError.self) {
            try await VMIntentConsent.run(prompting: { _ in asked += 1 }) { confirmed in
                try await gateway.stop(UUID(), disposition: .graceful, confirmed: confirmed)
            }
        }

        #expect(asked == 0)
        #expect(commands.stopCalls.map(\.confirmed) == [false])
    }

    @Test("A failure that is not a consent refusal is never turned into a question")
    func consentLeavesOtherFailuresAlone() async throws {
        let commands = MockVMCommanding()
        commands.stopError = CommandError.busy(vm: makeSummary(), operation: "suspending")
        let gateway = makeGateway(commands, defaults: makeStore("consent-other-failures"))
        var asked = 0

        await #expect(throws: CommandError.self) {
            try await VMIntentConsent.run(prompting: { _ in asked += 1 }) { confirmed in
                try await gateway.stop(UUID(), disposition: .graceful, confirmed: confirmed)
            }
        }

        #expect(asked == 0)
        #expect(commands.stopCalls.count == 1)
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

    @Test("Readiness writes the whole library, emptying nothing")
    func readinessSyncsTheWholeLibrary() async throws {
        let commands = MockVMCommanding()
        let first = makeSummary(name: "First")
        let second = makeSummary(name: "Second")
        commands.library = [first, second]
        let index = MockVMEntityIndex()
        let defaults = makeStore("readiness-sync")
        let gateway = makeGateway(commands, defaults: defaults, index: index)

        try await index.gate.wait { index.operations.count == Self.syncedOperations }

        #expect(index.operations == [.index([first.id, second.id])])
        #expect(indexedIDs(in: defaults) == [first.id, second.id])
        withExtendedLifetime(gateway) {}
    }

    @Test("Readiness drops only the VMs it recorded indexing that the library no longer holds")
    func readinessPrunesWhatLeftTheLibrary() async throws {
        let commands = MockVMCommanding()
        let kept = makeSummary(name: "Kept")
        commands.library = [kept]
        let gone = UUID()
        let defaults = makeStore("readiness-prune")
        defaults.set(
            [gone.uuidString, kept.id.uuidString], forKey: VMIntentGateway.indexedVMIDsKey)
        let index = MockVMEntityIndex()
        let gateway = makeGateway(commands, defaults: defaults, index: index)

        // The write lands before the prune, so a process ending between them
        // leaves the library findable rather than nothing at all.
        try await index.gate.wait { index.operations.count == 2 }

        #expect(index.operations == [.index([kept.id]), .remove([gone])])
        #expect(indexedIDs(in: defaults) == [kept.id])
        withExtendedLifetime(gateway) {}
    }

    @Test("A refused whole-library write keeps the recorded VMs, and the next batch re-attempts it")
    func refusedSyncIsRetriedOnTheNextBatch() async throws {
        let commands = MockVMCommanding()
        let vm = makeSummary(name: "Wired")
        commands.library = [vm]
        let stale = UUID()
        let defaults = makeStore("sync-retry")
        defaults.set([stale.uuidString], forKey: VMIntentGateway.indexedVMIDsKey)
        let index = MockVMEntityIndex()
        index.indexError = CocoaError(.fileWriteUnknown)
        let gateway = makeGateway(commands, defaults: defaults, index: index)

        try await index.gate.wait { index.operations.count == Self.syncedOperations }
        #expect(index.operations == [.index([vm.id])])
        #expect(indexedIDs(in: defaults) == [stale])

        index.indexError = nil
        // A status change shows neither surface anything new, and is still the
        // moment the refused write is re-attempted.
        commands.emit([.statusChanged(id: vm.id, name: "Wired", from: "stopped", to: "running")])

        try await index.gate.wait { index.operations.count == Self.syncedOperations + 1 }
        #expect(index.operations == [.index([vm.id]), .index([vm.id])])
        #expect(indexedIDs(in: defaults) == [stale, vm.id])
        withExtendedLifetime(gateway) {}
    }

    @Test("A refused removal is retried on the next batch, and forgotten only once it lands")
    func refusedRemovalIsRetriedOnTheNextBatch() async throws {
        let commands = MockVMCommanding()
        let kept = makeSummary(name: "Kept")
        let gone = makeSummary(name: "Gone")
        commands.library = [kept, gone]
        let defaults = makeStore("remove-retry")
        let index = MockVMEntityIndex()
        let gateway = makeGateway(commands, defaults: defaults, index: index)

        try await index.gate.wait { index.operations.count == Self.syncedOperations }
        #expect(indexedIDs(in: defaults) == [kept.id, gone.id])

        index.removeError = CocoaError(.fileWriteUnknown)
        commands.library = [kept]
        commands.emit([.removed(id: gone.id, name: "Gone")])

        try await index.gate.wait { index.operations.count == Self.syncedOperations + 1 }
        #expect(index.operations.last == .remove([gone.id]))
        #expect(indexedIDs(in: defaults) == [kept.id, gone.id])

        index.removeError = nil
        commands.emit([.statusChanged(id: kept.id, name: "Kept", from: "stopped", to: "running")])

        try await index.gate.wait { index.operations.count == Self.syncedOperations + 2 }
        #expect(index.operations.last == .remove([gone.id]))
        #expect(indexedIDs(in: defaults) == [kept.id])
        withExtendedLifetime(gateway) {}
    }

    @Test("A batch of additions is written once, however many VMs arrived")
    func aBatchOfAdditionsIsWrittenOnce() async throws {
        let commands = MockVMCommanding()
        let arriving = (1...6).map { makeSummary(name: "VM \($0)") }
        let index = MockVMEntityIndex()
        let gateway = makeGateway(commands, defaults: makeStore("batch-additions"), index: index)

        try await index.gate.wait { index.operations.count == Self.syncedOperations }

        // The launch case: one pass over the library reports every VM it holds.
        commands.library = arriving
        commands.emit(arriving.map { .added($0) })

        try await index.gate.wait { index.operations.count == Self.syncedOperations + 1 }
        #expect(index.operations.last == .index(arriving.map(\.id)))
        withExtendedLifetime(gateway) {}
    }

    @Test("A batch's removals are dropped and its renames re-indexed; status changes touch neither")
    func indexFollowsTheLibrary() async throws {
        let commands = MockVMCommanding()
        let kept = makeSummary(name: "Kept")
        commands.library = [kept]
        let gone = UUID()
        let index = MockVMEntityIndex()
        let gateway = makeGateway(commands, defaults: makeStore("index-follows"), index: index)

        try await index.gate.wait { index.operations.count == Self.syncedOperations }

        // Ordered through one stream: the status-only batch is drained before
        // the batch whose writes are awaited, so the count proves it wrote
        // nothing.
        commands.emit([.statusChanged(id: kept.id, name: "Kept", from: "stopped", to: "running")])
        commands.emit([
            .removed(id: gone, name: "Gone"),
            .renamed(id: kept.id, from: "Was", to: "Kept"),
        ])

        try await index.gate.wait { index.operations.count == Self.syncedOperations + 2 }
        #expect(
            index.operations == [.index([kept.id]), .remove([gone]), .index([kept.id])])
        withExtendedLifetime(gateway) {}
    }

    @Test("A Spotlight refusal is swallowed, leaving the batch behind it indexed")
    func indexRefusalsAreSwallowed() async throws {
        let commands = MockVMCommanding()
        let vm = makeSummary(name: "Wired")
        commands.library = [vm]
        let index = MockVMEntityIndex()
        index.indexError = CocoaError(.fileWriteUnknown)
        let defaults = makeStore("index-refusals")
        let gateway = makeGateway(commands, defaults: defaults, index: index)

        try await index.gate.wait { index.operations.count == Self.syncedOperations }
        commands.emit([.renamed(id: vm.id, from: "Was", to: "Wired")])
        try await index.gate.wait { index.operations.count == Self.syncedOperations + 1 }

        index.indexError = nil
        commands.emit([.added(vm)])

        try await index.gate.wait { index.operations.count == Self.syncedOperations + 2 }
        #expect(Array(index.operations.suffix(2)) == [.index([vm.id]), .index([vm.id])])
        withExtendedLifetime(gateway) {}
    }

    // MARK: - Idle Reporting

    /// A ready gateway over a seeded mock, reporting every idle transition
    /// into `log` and noting any that arrived while work was outstanding.
    private func makeIdleReportingGateway(
        _ commands: MockVMCommanding, store: String, log: IdleLog
    ) -> VMIntentGateway {
        let box = GatewayBox()
        let gateway = VMIntentGateway(
            commands: commands,
            awaitReady: {},
            index: MockVMEntityIndex(),
            defaults: makeStore(store),
            onIdle: {
                if box.gateway?.hasIntentInFlight == true { log.reportedWhileBusy = true }
                log.count += 1
                log.gate.notify()
            })
        box.gateway = gateway
        return gateway
    }

    @Test("One intent reports the process idle once, and not before its result is built")
    func singleIntentReportsIdleOnce() async throws {
        let log = IdleLog()
        let gateway = makeIdleReportingGateway(MockVMCommanding(), store: "idle-single", log: log)

        gateway.beginIntent()
        #expect(gateway.hasIntentInFlight)
        gateway.endIntent()
        // Deferred, so the value the intent has just built reaches the framework
        // before anything can act on the process being idle.
        #expect(log.count == 0)
        #expect(!gateway.hasIntentInFlight)

        try await log.gate.wait { log.count == 1 }
        #expect(!log.reportedWhileBusy)
    }

    @Test("Overlapping intents report idle once, at the end of the last one")
    func overlappingIntentsReportIdleOnce() async throws {
        let log = IdleLog()
        let gateway = makeIdleReportingGateway(MockVMCommanding(), store: "idle-overlapping", log: log)

        gateway.beginIntent()
        gateway.beginIntent()
        gateway.endIntent()
        #expect(gateway.hasIntentInFlight)

        gateway.endIntent()
        try await log.gate.wait { log.count == 1 }
        #expect(log.count == 1)
        #expect(!log.reportedWhileBusy)
    }

    @Test("An intent arriving behind a finished one is never reported idle through")
    func reportIsCancelledByLaterIntent() async throws {
        let log = IdleLog()
        let gateway = makeIdleReportingGateway(MockVMCommanding(), store: "idle-cancelled", log: log)

        // The second intent lands on the same turn the first one's report was
        // scheduled from; re-testing the count is what keeps it from firing.
        gateway.beginIntent()
        gateway.endIntent()
        gateway.beginIntent()
        gateway.endIntent()

        try await log.gate.wait { log.count >= 1 }
        #expect(!log.reportedWhileBusy)
    }

    @Test("Reads the system issues on its own never report idle")
    func systemIssuedReadsDoNotReportIdle() async throws {
        let vm = UUID()
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Wired", id: vm)]
        let log = IdleLog()
        let gateway = makeIdleReportingGateway(commands, store: "idle-system-reads", log: log)

        // `VMEntityQuery` and `SnapshotEntityQuery` reach these to resolve a
        // parameter. Those reads arrive unbidden, so counting one would report
        // the process idle before the intent being resolved for had been
        // delivered.
        #expect(await gateway.vms().count == 1)
        #expect(await gateway.vms(matching: "Wired").count == 1)
        #expect(await gateway.vms(withIDs: [vm]).count == 1)
        #expect(try await gateway.snapshots(ofVM: vm).isEmpty)

        #expect(log.count == 0)
        #expect(!gateway.hasIntentInFlight)
    }
}

/// Holds the gateway the idle callback inspects, which cannot be captured
/// before it exists.
@MainActor
private final class GatewayBox {
    weak var gateway: VMIntentGateway?
}

/// How many times the gateway reported every intent finished.
@MainActor
private final class IdleLog {
    var count = 0
    /// Set if a report ever arrived while an intent was still executing — the
    /// one thing that must never happen, since `NSApp.terminate` does not return.
    var reportedWhileBusy = false
    let gate = AsyncGate()
}

/// Counts calls arriving from whatever isolation the value under test uses.
private actor Counter {
    private(set) var value = 0

    func increment() { value += 1 }
}
