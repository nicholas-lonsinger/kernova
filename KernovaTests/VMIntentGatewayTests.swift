import AppIntents
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The App Intents front door: what Siri, Shortcuts, and Spotlight see, how it
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
        refreshShortcutVocabulary: @escaping @MainActor () -> Void = {}
    ) -> VMIntentGateway {
        VMIntentGateway(
            commands: commands, awaitReady: {},
            refreshShortcutVocabulary: refreshShortcutVocabulary)
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

        let resolved = await makeGateway(commands).vms(withIDs: [second.id])

        #expect(resolved.map(\.name) == ["Second"])
    }

    @Test("A spoken name matches case-insensitively, and every VM that answers to it")
    func lookupMatchesNamesCaseInsensitively() async throws {
        let commands = MockVMCommanding()
        commands.library = [
            makeSummary(name: "Sonoma"), makeSummary(name: "Sonoma"), makeSummary(name: "Ubuntu"),
        ]

        let gateway = makeGateway(commands)

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

        let all = await makeGateway(commands).vms()

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

        // Case-insensitive: a spoken library is not sorted by ASCII.
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
        let gateway = VMIntentGateway(
            commands: commands,
            awaitReady: {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            },
            refreshShortcutVocabulary: {})

        let read = Task { await gateway.vms() }
        for await _ in entered.stream { break }
        #expect(commands.listCallCount == 0)

        release.continuation.yield(())
        release.continuation.finish()

        #expect(await read.value.map(\.name) == ["Late"])
        #expect(commands.listCallCount == 1)
    }

    @Test("The library read is awaited once, however many intents pile onto it")
    func readinessIsMemoized() async throws {
        let commands = MockVMCommanding()
        let awaits = Counter()
        let gateway = VMIntentGateway(
            commands: commands, awaitReady: { await awaits.increment() },
            refreshShortcutVocabulary: {})

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
        let gateway = makeGateway(commands)

        try await gateway.start(id, recovery: true)
        try await gateway.stop(id, disposition: .force, confirmed: true)
        try await gateway.pause(id)
        try await gateway.resume(id)
        try await gateway.suspend(id)
        try await gateway.restart(id)
        try await gateway.open(id)
        _ = try await gateway.takeSnapshot(id, name: "Before", notes: "a note")
        _ = try await gateway.ipAddress(of: id)

        #expect(commands.startCalls.map(\.selector) == [.id(id)])
        #expect(commands.startCalls.map(\.recovery) == [true])
        #expect(commands.stopCalls.map(\.selector) == [.id(id)])
        #expect(commands.stopCalls.map(\.disposition) == [.force])
        #expect(commands.pauseSelectors == [.id(id)])
        #expect(commands.resumeSelectors == [.id(id)])
        #expect(commands.suspendSelectors == [.id(id)])
        #expect(commands.restartSelectors == [.id(id)])
        #expect(commands.openSelectors == [.id(id)])
        #expect(commands.ipAddressSelectors == [.id(id)])
        #expect(commands.takeSnapshotCalls.map(\.selector) == [.id(id)])
        #expect(commands.takeSnapshotCalls.map(\.name) == ["Before"])
        #expect(commands.takeSnapshotCalls.map(\.notes) == ["a note"])
    }

    @Test("A refusal from the core reaches the caller unchanged")
    func refusalsPassThrough() async throws {
        let commands = MockVMCommanding()
        commands.startError = CommandError.busy(vm: makeSummary(), operation: "starting")
        let gateway = makeGateway(commands)

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
        let gateway = makeGateway(commands)
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
        let gateway = makeGateway(commands)
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
        let gateway = makeGateway(commands)
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
        let gateway = makeGateway(commands)
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

    // MARK: - Shortcut Vocabulary

    @Test("A rename refreshes Siri's VM vocabulary; a status change leaves it alone")
    func vocabularyFollowsTheLibrary() async throws {
        let commands = MockVMCommanding()
        let refreshes = AsyncStream<Void>.makeStream()
        let log = RefreshLog()
        let gateway = makeGateway(commands) {
            log.count += 1
            refreshes.continuation.yield(())
        }

        // Ordered, so the count proves the status change contributed nothing:
        // it is drained before the rename that produces the awaited refresh.
        commands.emit(.statusChanged(id: UUID(), name: "Fresh", from: "stopped", to: "running"))
        commands.emit(.renamed(id: UUID(), from: "Old", to: "New"))

        for await _ in refreshes.stream { break }
        #expect(log.count == 1)
        #expect(await gateway.vms().isEmpty)
    }
}

/// Counts calls arriving from whatever isolation the value under test uses.
private actor Counter {
    private(set) var value = 0

    func increment() { value += 1 }
}

/// How many times the gateway asked for Siri's vocabulary to be rebuilt.
@MainActor
private final class RefreshLog {
    var count = 0
}
