import AppIntents
import Foundation
import KernovaKit
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
            commands: commands, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
    }

    /// A library of one VM, seeded with `snapshots`.
    private func seed(
        _ commands: MockVMCommanding, vm: UUID, snapshots: [SnapshotSummary] = []
    ) {
        commands.library = [VMSummary(id: vm, name: "Wired", status: "stopped", ipAddress: .unavailable)]
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
        seed(commands, vm: vm, snapshots: [VMIntentFixtures.snapshot(id: snapshot)])
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
        #expect(commands.renameSnapshotCalls.map(\.snapshot) == [snapshot])
        #expect(commands.renameSnapshotCalls.map(\.newName) == ["Renamed"])
        #expect(commands.setSnapshotNotesCalls.map(\.selector) == [.id(vm)])
        #expect(commands.setSnapshotNotesCalls.map(\.snapshot) == [snapshot])
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

    /// A pick is only as current as the run that made it: the snapshot it names
    /// can have been deleted, or dropped by a revert, between two runs of the
    /// same Shortcut. A rename or a note edit is a documented no-op for an
    /// identifier the manifest does not list, so the second run would report
    /// success having changed nothing.
    @Test("A snapshot the VM no longer lists is refused, not quietly written past")
    func aSnapshotTheVMNoLongerListsIsRefused() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        seed(commands, vm: vm, snapshots: [VMIntentFixtures.snapshot(name: "Kept")])
        let gone = SnapshotEntityID(vm: vm, snapshot: UUID())
        let refusal = CommandError.itemNotFound(
            vm: commands.library[0],
            item: "snapshot with the identifier \(gone.snapshot.uuidString)")
        let gateway = makeGateway(commands)

        await #expect(throws: refusal) {
            try await gateway.renameSnapshot(vm, snapshot: gone, to: "Renamed")
        }
        await #expect(throws: refusal) {
            try await gateway.setSnapshotNotes(vm, snapshot: gone, notes: "a note")
        }

        #expect(commands.renameSnapshotCalls.isEmpty)
        #expect(commands.setSnapshotNotesCalls.isEmpty)
    }

    /// A clone carries its source's snapshot identifiers, so an identifier the
    /// named VM lists can still be a pick made in the VM it was copied from —
    /// which the VM parameter's authority refuses rather than redirects.
    @Test("A pick from a clone's source is refused where the named VM lists that identifier")
    func aSnapshotPickedInACloneSourceIsRefused() async throws {
        let commands = MockVMCommanding()
        let clone = UUID()
        let shared = VMIntentFixtures.snapshot(name: "Before Update")
        seed(commands, vm: clone, snapshots: [shared])
        let pickedInTheSource = SnapshotEntityID(vm: UUID(), snapshot: shared.id)
        let gateway = makeGateway(commands)

        await #expect(
            throws: CommandError.itemNotFound(
                vm: commands.library[0],
                item: "snapshot with the identifier \(shared.id.uuidString)")
        ) {
            try await gateway.renameSnapshot(clone, snapshot: pickedInTheSource, to: "Renamed")
        }

        #expect(commands.renameSnapshotCalls.isEmpty)
    }

    /// The core trims a snapshot name and writes nothing when none is left —
    /// the inline field commits on end-editing whether or not the text
    /// changed — so a Shortcut whose Name resolves to nothing would report
    /// success having renamed nothing.
    @Test(
        "A rename carrying nothing but whitespace for a name is refused",
        arguments: ["", "   ", "\n\t "])
    func aRenameWithoutANameIsRefused(name: String) async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        let listed = VMIntentFixtures.snapshot()
        seed(commands, vm: vm, snapshots: [listed])
        let gateway = makeGateway(commands)

        await #expect(
            throws: CommandError.invalidArgument(
                "A name is at least one character that is not a space.")
        ) {
            try await gateway.renameSnapshot(
                vm, snapshot: SnapshotEntityID(vm: vm, snapshot: listed.id), to: name)
        }

        #expect(commands.renameSnapshotCalls.isEmpty)
    }

    /// An empty note is a legitimate value — it clears the note — so the note
    /// edit takes what the rename refuses.
    @Test("An empty note clears the note rather than being refused")
    func anEmptyNoteIsWritten() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        let listed = VMIntentFixtures.snapshot()
        seed(commands, vm: vm, snapshots: [listed])
        let gateway = makeGateway(commands)

        try await gateway.setSnapshotNotes(
            vm, snapshot: SnapshotEntityID(vm: vm, snapshot: listed.id), notes: "")

        #expect(commands.setSnapshotNotesCalls.map(\.notes) == [""])
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
            VMConsentPolicy.revertAction(offered, takingCheckpoint: true)?.title
                == "Take Snapshot, Then Revert")
        // Capturing first loses nothing, so Shortcuts is not asked to mark it
        // destructive; the plain revert is.
        #expect(
            VMConsentPolicy.revertAction(offered, takingCheckpoint: true)?.isDestructive == false)
        #expect(VMConsentPolicy.revertAction(offered, takingCheckpoint: false)?.title == "Revert")
        #expect(
            VMConsentPolicy.revertAction(offered, takingCheckpoint: false)?.isDestructive == true)
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

        #expect(VMConsentPolicy.revertAction(unoffered, takingCheckpoint: true) == nil)
        #expect(VMConsentPolicy.revertAction(unoffered, takingCheckpoint: false)?.title == "Revert")
    }

    // MARK: - Consent

    @Test("A revert asks once, then re-issues carrying the checkpoint that was chosen")
    func revertConsentCarriesTheCheckpointChoice() async throws {
        for takingCheckpoint in [true, false] {
            let commands = MockVMCommanding()
            let vm = UUID()
            let listed = VMIntentFixtures.snapshot()
            let snapshot = SnapshotEntityID(vm: vm, snapshot: listed.id)
            seed(commands, vm: vm, snapshots: [listed])
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

            try await VMConsentPolicy.run(prompting: { asked.append($0) }) { confirmed in
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
        let listed = VMIntentFixtures.snapshot()
        seed(commands, vm: vm, snapshots: [listed])
        let refusal = CommandError.invalidState(
            vm: commands.library[0], current: .running, allowed: [.stop])
        commands.revertError = refusal
        let gateway = makeGateway(commands)

        await #expect(throws: refusal) {
            try await gateway.revertToSnapshot(
                vm, snapshot: SnapshotEntityID(vm: vm, snapshot: listed.id), takingCheckpoint: true,
                confirmed: true)
        }
    }

    @Test("A snapshot delete asks once and re-issues with the consent")
    func deleteSnapshotConsentRetriesTheVerb() async throws {
        let commands = MockVMCommanding()
        let vm = UUID()
        let listed = VMIntentFixtures.snapshot()
        seed(commands, vm: vm, snapshots: [listed])
        commands.deleteSnapshotConsentPrompt = ConfirmationPrompt(
            kind: .deleteSnapshot,
            title: "Delete?",
            message: "Moves the snapshot's files to the Trash.",
            confirmTitle: "Delete",
            dismissTitle: "Cancel")
        let gateway = makeGateway(commands)
        var asked: [ConfirmationPrompt] = []

        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { confirmed in
            try await gateway.deleteSnapshot(
                vm, snapshot: SnapshotEntityID(vm: vm, snapshot: listed.id), confirmed: confirmed)
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
