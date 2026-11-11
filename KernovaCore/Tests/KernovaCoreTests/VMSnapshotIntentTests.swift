import AppIntents
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

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

    // MARK: - Verb Dispatch

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
