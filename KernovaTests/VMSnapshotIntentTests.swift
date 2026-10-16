import AppIntents
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The snapshot-addressing half of the App Intents surface: how Shortcuts names
/// one snapshot, and what each snapshot verb does to the VM it names.
///
/// Driven through the gateway rather than through the intents, which resolve
/// their `@Dependency` only inside a live intent session.
@Suite("VM Snapshot Intent Tests", .caseScoped)
@MainActor
struct VMSnapshotIntentTests {
    private func makeGateway(_ wired: WiredCommandCore) -> VMIntentGateway {
        VMIntentGateway(
            commands: wired.core, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
    }

    /// A stopped VM listing `snapshots`, each with a captured configuration a
    /// revert can restore.
    @discardableResult
    private func register(
        in wired: WiredCommandCore, name: String = "Wired", snapshots: [VMSnapshot]
    ) -> VMInstance {
        let instance = wired.register(name: name, snapshots: snapshots)
        for snapshot in snapshots {
            wired.machineFiles.setCapturedConfiguration(instance.configuration, for: snapshot.id)
        }
        return instance
    }

    /// What a manifest lists of a snapshot that a verb could change. The
    /// manifest stores `createdAt` at a coarser precision than `Date()`, so a
    /// whole-snapshot comparison against the fixture fails on the date alone.
    private struct Listed: Equatable {
        let id: UUID
        let name: String
        let notes: String
    }

    private func listing(of snapshots: [VMSnapshot]) -> [Listed] {
        snapshots.map { Listed(id: $0.id, name: $0.name, notes: $0.notes) }
    }

    private func listing(of vm: VMInstance) -> [Listed] {
        listing(of: vm.snapshotManifest.snapshots)
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
        #expect(
            String(localized: subtitle)
                == SnapshotEntity.captureDescription(summary.kind, summary.createdAt))
    }

    @Test("Every capture names its state beside its date")
    func capturesReadBackTheirState() {
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        let date = SnapshotDateFormat.string(from: taken)

        #expect(
            SnapshotEntity.captureDescription("warm", taken)
                == "\(date) \u{00B7} \(SnapshotKindCopy.stateLabel(.warm))")
        #expect(
            SnapshotEntity.captureDescription("cold", taken)
                == "\(date) \u{00B7} \(SnapshotKindCopy.stateLabel(.cold))")
    }

    // MARK: - Reads

    @Test("The snapshot read answers entities carrying the VM that lists them, newest first")
    func snapshotsCarryTheirVM() async throws {
        let wired = WiredCommandCore()
        let older = VMSnapshot(
            name: "First", createdAt: Date(timeIntervalSince1970: 1_700_000_000), macAddress: nil)
        let newer = VMSnapshot(
            name: "Second", createdAt: Date(timeIntervalSince1970: 1_700_001_000), macAddress: nil)
        let vm = register(in: wired, snapshots: [older, newer])
        register(in: wired, snapshots: [VMSnapshot(name: "Twin's", macAddress: nil)])

        let snapshots = try await makeGateway(wired).snapshots(ofVM: vm.id)

        #expect(snapshots.map(\.name) == ["Second", "First"])
        #expect(
            snapshots.map(\.id) == [
                SnapshotEntityID(vm: vm.id, snapshot: newer.id),
                SnapshotEntityID(vm: vm.id, snapshot: older.id),
            ])
    }

    // MARK: - Verb Dispatch

    @Test("Every snapshot verb addresses its VM by identifier and names its snapshot")
    func verbsAddressBothTheVMAndTheSnapshot() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let target = VMSnapshot(name: "Target", kind: .cold, macAddress: nil)
        let deleted = VMSnapshot(name: "Deleted", kind: .cold, macAddress: nil)
        let vm = register(in: wired, snapshots: [target, deleted])
        let twinSnapshot = VMSnapshot(name: "Twin's", kind: .cold, macAddress: nil)
        let twin = register(in: wired, snapshots: [twinSnapshot])
        let gateway = makeGateway(wired)

        try await gateway.revertToSnapshot(
            vm.id, snapshot: SnapshotEntityID(vm: vm.id, snapshot: target.id), consent: .all)
        try await gateway.renameSnapshot(
            vm.id, snapshot: SnapshotEntityID(vm: vm.id, snapshot: target.id), to: "Renamed")
        try await gateway.setSnapshotNotes(
            vm.id, snapshot: SnapshotEntityID(vm: vm.id, snapshot: target.id), notes: "a note")
        try await gateway.deleteSnapshot(
            vm.id, snapshot: SnapshotEntityID(vm: vm.id, snapshot: deleted.id), consent: .all)

        #expect(virtualization.revertedSnapshots.map(\.id) == [target.id])
        #expect(vm.snapshotManifest.currentID == target.id)
        #expect(vm.snapshotManifest.snapshots.map(\.id) == [target.id])
        let renamed = try #require(vm.snapshotManifest.snapshot(id: target.id))
        #expect(renamed.name == "Renamed")
        #expect(renamed.notes == "a note")
        #expect(wired.machineFiles.discardedIDs == [deleted.id])
        // The twin answering to the same name is untouched.
        #expect(listing(of: twin) == listing(of: [twinSnapshot]))
        #expect(twin.snapshotManifest.currentID == nil)
    }

    /// The VM parameter is authoritative, and the refusal is the surface's own:
    /// a rename or a note edit is a documented no-op for an identifier the
    /// manifest does not list, so without this the mismatch would reach the
    /// core, change nothing, and report success.
    @Test("A snapshot picked from another VM is refused by every verb, never quietly dropped")
    func aSnapshotFromAnotherVMIsRefused() async throws {
        let wired = WiredCommandCore()
        let named = register(in: wired, snapshots: [])
        let other = VMSnapshot(name: "Elsewhere", kind: .cold, macAddress: nil)
        let elsewhere = register(in: wired, name: "Elsewhere", snapshots: [other])
        let stale = SnapshotEntityID(vm: elsewhere.id, snapshot: other.id)
        let refusal = CommandError.itemNotFound(
            vm: wired.core.summary(named),
            item: "snapshot with the identifier \(other.id.uuidString)")
        let gateway = makeGateway(wired)

        await #expect(throws: refusal) {
            try await gateway.revertToSnapshot(named.id, snapshot: stale, consent: .all)
        }
        await #expect(throws: refusal) {
            try await gateway.deleteSnapshot(named.id, snapshot: stale, consent: .all)
        }
        await #expect(throws: refusal) {
            try await gateway.renameSnapshot(named.id, snapshot: stale, to: "Renamed")
        }
        await #expect(throws: refusal) {
            try await gateway.setSnapshotNotes(named.id, snapshot: stale, notes: "a note")
        }

        #expect(listing(of: elsewhere) == listing(of: [other]))
        #expect(elsewhere.snapshotManifest.currentID == nil)
        #expect(named.snapshotManifest.isEmpty)
    }

    /// A pick is only as current as the run that made it: the snapshot it names
    /// can have been deleted, or dropped by a revert, between two runs of the
    /// same Shortcut. A rename or a note edit is a documented no-op for an
    /// identifier the manifest does not list, so the second run would report
    /// success having changed nothing.
    @Test("A snapshot the VM no longer lists is refused, not quietly written past")
    func aSnapshotTheVMNoLongerListsIsRefused() async throws {
        let wired = WiredCommandCore()
        let kept = VMSnapshot(name: "Kept", macAddress: nil)
        let vm = register(in: wired, snapshots: [kept])
        let gone = SnapshotEntityID(vm: vm.id, snapshot: UUID())
        let refusal = CommandError.itemNotFound(
            vm: wired.core.summary(vm),
            item: "snapshot with the identifier \(gone.snapshot.uuidString)")
        let gateway = makeGateway(wired)

        await #expect(throws: refusal) {
            try await gateway.renameSnapshot(vm.id, snapshot: gone, to: "Renamed")
        }
        await #expect(throws: refusal) {
            try await gateway.setSnapshotNotes(vm.id, snapshot: gone, notes: "a note")
        }

        #expect(listing(of: vm) == listing(of: [kept]))
    }

    /// A clone carries its source's snapshot identifiers, so an identifier the
    /// named VM lists can still be a pick made in the VM it was copied from —
    /// which the VM parameter's authority refuses rather than redirects.
    @Test("A pick from a clone's source is refused where the named VM lists that identifier")
    func aSnapshotPickedInACloneSourceIsRefused() async throws {
        let wired = WiredCommandCore()
        let shared = VMSnapshot(name: "Before Update", macAddress: nil)
        let source = register(in: wired, name: "Source", snapshots: [shared])
        let clone = register(in: wired, name: "Source Copy", snapshots: [shared])
        let pickedInTheSource = SnapshotEntityID(vm: source.id, snapshot: shared.id)

        await #expect(
            throws: CommandError.itemNotFound(
                vm: wired.core.summary(clone),
                item: "snapshot with the identifier \(shared.id.uuidString)")
        ) {
            try await makeGateway(wired).renameSnapshot(
                clone.id, snapshot: pickedInTheSource, to: "Renamed")
        }

        #expect(listing(of: clone) == listing(of: [shared]))
        #expect(listing(of: source) == listing(of: [shared]))
    }

    /// The core trims a snapshot name and writes nothing when none is left —
    /// the inline field commits on end-editing whether or not the text
    /// changed — so a Shortcut whose Name resolves to nothing would report
    /// success having renamed nothing.
    @Test(
        "A rename carrying nothing but whitespace for a name is refused",
        arguments: ["", "   ", "\n\t "])
    func aRenameWithoutANameIsRefused(name: String) async throws {
        let wired = WiredCommandCore()
        let listed = VMSnapshot(name: "Listed", macAddress: nil)
        let vm = register(in: wired, snapshots: [listed])

        await #expect(
            throws: CommandError.invalidArgument(
                "A name is at least one character that is not a space.")
        ) {
            try await makeGateway(wired).renameSnapshot(
                vm.id, snapshot: SnapshotEntityID(vm: vm.id, snapshot: listed.id), to: name)
        }

        #expect(listing(of: vm) == listing(of: [listed]))
    }

    /// An empty note is a legitimate value — it clears the note — so the note
    /// edit takes what the rename refuses.
    @Test("An empty note clears the note rather than being refused")
    func anEmptyNoteIsWritten() async throws {
        let wired = WiredCommandCore()
        let listed = VMSnapshot(name: "Listed", notes: "an old note", macAddress: nil)
        let vm = register(in: wired, snapshots: [listed])

        try await makeGateway(wired).setSnapshotNotes(
            vm.id, snapshot: SnapshotEntityID(vm: vm.id, snapshot: listed.id), notes: "")

        #expect(vm.snapshotManifest.snapshot(id: listed.id)?.notes == "")
    }

    // MARK: - Consent

    @Test("A revert asks once, then re-issues with the consent")
    func revertConsentRetriesTheVerb() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let listed = VMSnapshot(name: "Clean", kind: .cold, macAddress: nil)
        let vm = register(in: wired, snapshots: [listed])
        let prompt = VMCommandCore.revertPrompt(listed, on: vm)
        let gateway = makeGateway(wired)
        var asked: [ConfirmationPrompt] = []

        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { consent in
            try await gateway.revertToSnapshot(
                vm.id, snapshot: SnapshotEntityID(vm: vm.id, snapshot: listed.id), consent: consent)
        }

        #expect(asked == [prompt])
        #expect(virtualization.revertedSnapshots.map(\.id) == [listed.id])
        #expect(vm.snapshotManifest.currentID == listed.id)
    }

    /// The revert can still fail once consent is in — and the caller is told,
    /// rather than getting a success for a rollback that did not happen.
    @Test("A revert that fails after consent refuses rather than reporting success")
    func revertSurfacesAFailureAfterConsent() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.revertToSnapshotError = CocoaError(.fileWriteOutOfSpace)
        let wired = WiredCommandCore(virtualization: virtualization)
        let listed = VMSnapshot(name: "Clean", kind: .cold, macAddress: nil)
        let vm = register(in: wired, snapshots: [listed])

        await #expect(throws: CommandError.self) {
            try await makeGateway(wired).revertToSnapshot(
                vm.id, snapshot: SnapshotEntityID(vm: vm.id, snapshot: listed.id), consent: .all)
        }

        #expect(virtualization.revertedSnapshots.isEmpty)
        #expect(vm.snapshotManifest.currentID == nil)
    }

    @Test("A snapshot delete asks once and re-issues with the consent")
    func deleteSnapshotConsentRetriesTheVerb() async throws {
        let wired = WiredCommandCore()
        let listed = VMSnapshot(name: "Before", macAddress: nil)
        let vm = register(in: wired, snapshots: [listed])
        let prompt = VMCommandCore.deleteSnapshotPrompt(listed, on: vm)
        let gateway = makeGateway(wired)
        var asked: [ConfirmationPrompt] = []

        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { consent in
            try await gateway.deleteSnapshot(
                vm.id, snapshot: SnapshotEntityID(vm: vm.id, snapshot: listed.id), consent: consent)
        }

        #expect(asked == [prompt])
        #expect(vm.snapshotManifest.isEmpty)
        #expect(wired.machineFiles.discardedIDs == [listed.id])
    }
}
