import AppIntents
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The snapshot-addressing half of the App Intents surface: how Shortcuts names
/// one snapshot, and what each snapshot verb dispatches.
///
/// Driven through the gateway rather than through the intents, which resolve
/// their `@Dependency` only inside a live intent session.
@Suite("VM Snapshot Intent Tests")
@MainActor
struct VMSnapshotIntentTests {
    private func makeGateway(_ commands: MockVMCommanding) -> VMIntentGateway {
        VMIntentGateway(
            commands: commands, awaitReady: {},
            index: MockVMEntityIndex(),
            defaults: makeEphemeralDefaults(suiteName: "test.kernova.intents.snapshot"))
    }

    /// A library of one VM, seeded with `snapshots`.
    private func seed(
        _ commands: MockVMCommanding, vm: UUID, snapshots: [SnapshotSummary] = []
    ) {
        commands.library = [VMSummary(id: vm, name: "Wired", status: "stopped")]
        commands.snapshotsByVM[vm] = snapshots
    }

    // MARK: - Identity

    @Test("A snapshot identifier round-trips through the string Shortcuts persists")
    func identifierRoundTrips() throws {
        let id = SnapshotEntityID(vm: UUID(), snapshot: UUID())

        let restored = try #require(
            SnapshotEntityID.entityIdentifier(for: id.entityIdentifierString))

        #expect(restored == id)
        #expect(restored.vm == id.vm)
        #expect(restored.snapshot == id.snapshot)
    }

    @Test("An identifier string that is not a VM and a snapshot resolves to nothing")
    func malformedIdentifiersResolveToNothing() {
        let vm = UUID().uuidString
        let malformed = [
            "", "/", vm, "\(vm)/", "/\(vm)", "\(vm)/not-a-uuid", "not-a-uuid/\(vm)",
            "\(vm)/\(vm)/\(vm)",
        ]

        for candidate in malformed {
            #expect(SnapshotEntityID.entityIdentifier(for: candidate) == nil)
        }
    }

    // MARK: - Entity

    @Test("An entity carries the summary it was built from, under a VM-scoped identifier")
    func entityDescribesItsSummary() throws {
        let vm = UUID()
        let summary = VMIntentFixtures.snapshot(
            name: "Before Update", notes: "clean install", kind: "warm", isCurrent: true)

        let entity = SnapshotEntity(summary, vm: vm)

        #expect(entity.id == SnapshotEntityID(vm: vm, snapshot: summary.id))
        #expect(entity.name == "Before Update")
        #expect(entity.notes == "clean install")
        #expect(entity.kind == "warm")
        #expect(entity.createdAt == summary.createdAt)
        #expect(entity.isCurrent)
        #expect(!entity.isEphemeralBaseline)
        #expect(String(localized: entity.displayRepresentation.title) == "Before Update")
        let subtitle = try #require(entity.displayRepresentation.subtitle)
        #expect(String(localized: subtitle) == SnapshotDateFormat.string(from: summary.createdAt))
    }

    @Test("A capture holding no memory image says so beside its date")
    func coldCapturesReadBackAsDisksOnly() {
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        let date = SnapshotDateFormat.string(from: taken)

        #expect(SnapshotEntity.captureDescription("warm", taken) == date)
        #expect(SnapshotEntity.captureDescription("cold", taken) == "\(date) \u{00B7} Disks only")
    }

    // MARK: - Reads

    @Test("The snapshot read answers entities carrying the VM that lists them")
    func snapshotsCarryTheirVM() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        let first = VMIntentFixtures.snapshot(name: "First")
        let second = VMIntentFixtures.snapshot(name: "Second")
        seed(commands, vm: vm, snapshots: [first, second])

        let snapshots = try await makeGateway(commands).snapshots(ofVM: vm)

        #expect(snapshots.map(\.name) == ["First", "Second"])
        #expect(
            snapshots.map(\.id) == [
                SnapshotEntityID(vm: vm, snapshot: first.id),
                SnapshotEntityID(vm: vm, snapshot: second.id),
            ])
        #expect(commands.snapshotsSelectors == [.id(vm)])
    }

    // MARK: - Verb Dispatch

    @Test("Every snapshot verb addresses its VM by identifier and names its snapshot")
    func verbsAddressBothTheVMAndTheSnapshot() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        let snapshot = UUID()
        let picked = SnapshotEntityID(vm: vm, snapshot: snapshot)
        seed(commands, vm: vm)
        let gateway = makeGateway(commands)

        try await gateway.revertToSnapshot(
            vm, snapshot: picked, takingCheckpoint: true, confirmed: true)
        try await gateway.deleteSnapshot(vm, snapshot: picked, confirmed: true)
        try await gateway.renameSnapshot(vm, snapshot: picked, to: "Renamed")
        try await gateway.setSnapshotNotes(vm, snapshot: picked, notes: "a note")

        #expect(commands.revertCalls.map(\.selector) == [.id(vm)])
        #expect(commands.revertCalls.map(\.snapshot) == [snapshot])
        #expect(commands.deleteSnapshotCalls.map(\.selector) == [.id(vm)])
        #expect(commands.deleteSnapshotCalls.map(\.snapshot) == [snapshot])
        #expect(commands.renameSnapshotCalls.map(\.selector) == [.id(vm)])
        #expect(commands.renameSnapshotCalls.map(\.newName) == ["Renamed"])
        #expect(commands.setSnapshotNotesCalls.map(\.selector) == [.id(vm)])
        #expect(commands.setSnapshotNotesCalls.map(\.notes) == ["a note"])
    }

    /// The VM parameter is authoritative, and the refusal is the surface's own:
    /// a rename or a note edit is a documented no-op for an identifier the
    /// manifest does not list, so without this the mismatch would reach the
    /// core, change nothing, and report success.
    @Test("A snapshot picked from another VM is refused by every verb, never quietly dropped")
    func aSnapshotFromAnotherVMIsRefused() async throws {
        let commands = MockVMCommanding()
        let named = UUID()
        seed(commands, vm: named)
        let stale = SnapshotEntity(VMIntentFixtures.snapshot(), vm: UUID()).id
        let gateway = makeGateway(commands)

        await #expect(throws: CommandError.self) {
            try await gateway.revertToSnapshot(
                named, snapshot: stale, takingCheckpoint: false, confirmed: true)
        }
        await #expect(throws: CommandError.self) {
            try await gateway.deleteSnapshot(named, snapshot: stale, confirmed: true)
        }
        await #expect(throws: CommandError.self) {
            try await gateway.renameSnapshot(named, snapshot: stale, to: "Renamed")
        }
        await #expect(throws: CommandError.self) {
            try await gateway.setSnapshotNotes(named, snapshot: stale, notes: "a note")
        }

        #expect(commands.revertCalls.isEmpty)
        #expect(commands.deleteSnapshotCalls.isEmpty)
        #expect(commands.renameSnapshotCalls.isEmpty)
        #expect(commands.setSnapshotNotesCalls.isEmpty)
    }

    // MARK: - Checkpoint

    /// The confirmation is labelled with the route the action chose, so a user
    /// confirming a checkpointed revert is not shown the plain one's words.
    @Test("The revert's confirm action names the route the checkpoint parameter chose")
    func theRevertConfirmationNamesTheChosenRoute() {
        let offered = ConfirmationPrompt(
            kind: .revertToSnapshot, title: "Revert?", message: "Guest changes are lost.",
            confirmTitle: "Revert", dismissTitle: "Cancel",
            alternatives: [
                ConfirmationAlternative(title: "Take Snapshot, Then Revert", takesCheckpoint: true)
            ])

        #expect(
            VMIntentConsent.revertAction(offered, takingCheckpoint: true)
                == "Take Snapshot, Then Revert")
        #expect(VMIntentConsent.revertAction(offered, takingCheckpoint: false) == "Revert")
    }

    /// A VM that can be reverted but can no longer be captured — one that
    /// failed to start, where reverting is the way out — is offered no
    /// checkpoint alternative, and that absence is what the intent refuses on
    /// rather than letting the capture fail after consent.
    @Test("A checkpoint the VM cannot take has no action to confirm")
    func aCheckpointThatCannotBeTakenHasNoAction() {
        let unoffered = ConfirmationPrompt(
            kind: .revertToSnapshot, title: "Revert?", message: "Guest changes are lost.",
            confirmTitle: "Revert", dismissTitle: "Cancel")

        #expect(VMIntentConsent.revertAction(unoffered, takingCheckpoint: true) == nil)
        #expect(VMIntentConsent.revertAction(unoffered, takingCheckpoint: false) == "Revert")
    }

    // MARK: - Consent

    @Test("A revert asks once, then re-issues carrying the checkpoint that was chosen")
    func revertConsentCarriesTheCheckpointChoice() async throws {
        for takingCheckpoint in [true, false] {
            let commands = MockVMCommanding()
            let vm = UUID()
            let snapshot = SnapshotEntityID(vm: vm, snapshot: UUID())
            seed(commands, vm: vm)
            commands.revertConsentPrompt = ConfirmationPrompt(
                kind: .revertToSnapshot,
                title: "Revert?",
                message: "Guest changes since then are lost.",
                confirmTitle: "Revert",
                dismissTitle: "Cancel",
                alternatives: [
                    ConfirmationAlternative(
                        title: "Take Snapshot, Then Revert", takesCheckpoint: true)
                ])
            let gateway = makeGateway(commands)
            var asked: [ConfirmationPrompt] = []

            try await VMIntentConsent.run(prompting: { asked.append($0) }) { confirmed in
                try await gateway.revertToSnapshot(
                    vm, snapshot: snapshot, takingCheckpoint: takingCheckpoint,
                    confirmed: confirmed)
            }

            #expect(asked.map(\.kind) == [.revertToSnapshot])
            #expect(commands.revertCalls.map(\.confirmed) == [false, true])
            #expect(
                commands.revertCalls.map(\.takingCheckpoint) == [takingCheckpoint, takingCheckpoint]
            )
        }
    }

    /// The core captures the checkpoint after the confirmation lands, so the
    /// revert can still fail once consent is in — and the caller is told,
    /// rather than getting a success for a rollback that did not happen.
    @Test("A revert that fails after consent refuses rather than reporting success")
    func revertSurfacesAFailureAfterConsent() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        seed(commands, vm: vm)
        commands.revertError = CommandError.invalidState(
            vm: commands.library[0], current: .running, allowed: [.stop])
        let gateway = makeGateway(commands)

        await #expect(throws: CommandError.self) {
            try await gateway.revertToSnapshot(
                vm, snapshot: SnapshotEntityID(vm: vm, snapshot: UUID()), takingCheckpoint: true,
                confirmed: true)
        }
    }

    @Test("A snapshot delete asks once and re-issues with the consent")
    func deleteSnapshotConsentRetriesTheVerb() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        seed(commands, vm: vm)
        commands.deleteSnapshotConsentPrompt = ConfirmationPrompt(
            kind: .deleteSnapshot,
            title: "Delete?",
            message: "Moves the snapshot's files to the Trash.",
            confirmTitle: "Delete",
            dismissTitle: "Cancel")
        let gateway = makeGateway(commands)
        var asked: [ConfirmationPrompt] = []

        try await VMIntentConsent.run(prompting: { asked.append($0) }) { confirmed in
            try await gateway.deleteSnapshot(
                vm, snapshot: SnapshotEntityID(vm: vm, snapshot: UUID()), confirmed: confirmed)
        }

        #expect(asked.map(\.kind) == [.deleteSnapshot])
        #expect(commands.deleteSnapshotCalls.map(\.confirmed) == [false, true])
    }

    // MARK: - Error Surfacing

    @Test("A refusal from the core reaches the caller unchanged")
    func refusalsPassThrough() async throws {
        let commands = MockVMCommanding()
        commands.snapshotsError = CommandError.notFound(.id(UUID()))

        await #expect(throws: CommandError.self) {
            try await makeGateway(commands).snapshots(ofVM: UUID())
        }
    }
}
