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

    @Test("Take Snapshot answers the snapshot it took, which a revert returns the VM to")
    func takenSnapshotIsTheRevertTarget() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let earlier = VMSnapshot(name: "Earlier", kind: .cold, macAddress: nil)
        let vm = register(in: wired, snapshots: [earlier])
        let gateway = makeGateway(wired)

        let taken = try await gateway.takeSnapshot(vm.id, name: "Before the run", notes: "")
        let added = try #require(vm.snapshotManifest.snapshots.first { $0.id != earlier.id })
        try await gateway.revertToSnapshot(vm.id, snapshot: taken.id, consent: .all)

        #expect(virtualization.revertedSnapshots.map(\.id) == [added.id])
    }

    // MARK: - Sizes

    @Test("Each snapshot's sizes are its own measurement")
    func sizesAreEachSnapshotsOwn() async throws {
        let wired = WiredCommandCore()
        let cloned = VMSnapshot(name: "Cloned", kind: .cold, macAddress: nil)
        let copied = VMSnapshot(name: "Copied", kind: .cold, macAddress: nil)
        let unreadable = VMSnapshot(name: "Unreadable", kind: .cold, macAddress: nil)
        let vm = register(in: wired, snapshots: [cloned, copied, unreadable])
        wired.machineFiles.setSnapshotSize(SnapshotSize(bytes: 8_192, privateBytes: 4_096), for: cloned.id)
        wired.machineFiles.setSnapshotSize(SnapshotSize(bytes: 12_288, privateBytes: nil), for: copied.id)
        let gateway = makeGateway(wired)

        var read: [UUID: [Int?]] = [:]
        for entity in try await gateway.snapshots(ofVM: vm.id) {
            read[entity.id.snapshot] = [try await entity.sizeBytes, try await entity.privateBytes]
        }

        #expect(read == [cloned.id: [8_192, 4_096], copied.id: [12_288, nil], unreadable.id: [nil, nil]])
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
