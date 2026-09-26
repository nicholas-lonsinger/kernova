import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The one ``VMLibrary/adopt(_:)`` every bundle enters the library through —
/// at launch, at a reconcile, and at an arrival's publication — and the cancel
/// an arrival decides before its rename.
@Suite("VMLibrary adoption", .serialized, .admissionGated)
@MainActor
struct VMLibraryAdoptionTests {
    private let preferences = makeTestPreferences()
    private let storage = MockVMStorageService()

    /// Every title the library handed its failure hook, in order.
    private final class Reports {
        var titles: [String] = []
    }

    /// What a hook running inside the library's work saw, read back after.
    private final class Captured<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func makeLibrary(reports: Reports? = nil) -> VMLibrary {
        let library = makeWiredLibrary(storage: storage, preferences: preferences)
        if let reports {
            library.onFailure = { title, _ in reports.titles.append(title) }
        }
        return library
    }

    private func configuration(_ name: String) -> VMConfiguration {
        VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
    }

    /// Writes `configuration` as the whole of a staged bundle, as a create does.
    private func writing(
        _ configuration: VMConfiguration
    ) -> (URL) async throws -> Void {
        let storage = storage
        return { staged in
            try storage.createVMBundle(at: staged)
            try VMBundleFiles(url: staged, access: storage.bundleFiles).writeInitial(configuration)
        }
    }

    private func bundleURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AdoptionTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("\(name).\(VMBundleFormat.fileExtension)", isDirectory: true)
    }

    // MARK: - Publication

    @Test("Adoption reads what disk holds after the rename, not what the staged tree held")
    func adoptionReadsWhatDiskHoldsAfterTheRename() async throws {
        let library = makeLibrary()
        let config = configuration("Written")
        let destination = try storage.bundleURL(for: config)
        var edited = config
        edited.name = "Edited on Disk"
        let onDisk = edited
        let files = storage.files
        storage.afterPublish = { files.setConfiguration(onDisk, at: destination) }

        let arrival = library.beginArrival(
            kind: .creating, configuration: config, destination: destination,
            write: writing(config))
        let instance = try await arrival.settled.value

        #expect(instance.name == "Edited on Disk")
        #expect(library.instances.map(\.name) == ["Edited on Disk"])
    }

    @Test("A reconcile that runs between the rename and the adoption leaves the arrival to its pipeline")
    func aReconcileBetweenTheRenameAndAdoptYieldsOneVM() async throws {
        let library = makeLibrary()
        let config = configuration("Raced")
        let destination = try storage.bundleURL(for: config)
        let reconciledEntries = Captured<[LibraryEntry]>([])
        storage.afterPublish = {
            library.reconcileWithDisk()
            reconciledEntries.value = library.entries
        }

        let arrival = library.beginArrival(
            kind: .creating, configuration: config, destination: destination,
            write: writing(config))
        let instance = try await arrival.settled.value

        // Only the arrival's own pipeline turns its row into a VM, since it
        // alone knows whether a cancel withdrew the bundle.
        #expect(reconciledEntries.value.count == 1)
        #expect(reconciledEntries.value.first?.arrival === arrival)
        #expect(library.entries.count == 1)
        #expect(library.instances.count == 1)
        #expect(library.instances.first === instance)
    }

    // MARK: - Moved Bundles

    @Test("A bundle moved within the VMs directory keeps its VM, re-bound to the new URL")
    func aBundleMovedWithinTheVMsDirectoryKeepsItsVMReboundToTheNewURL() {
        let library = makeLibrary()
        let instance = RegisteredVMInstanceFixture.register(
            name: "Mover", phase: .stopped, guestOS: .linux, library: library, storage: storage,
            preferences: preferences)
        let moved = bundleURL("Moved Here")

        storage.moveBundle(from: instance.bundleURL, to: moved)
        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first === instance)
        #expect(library.isSameBundle(instance.bundleURL, moved))
    }

    @Test("A write after the move lands in the bundle at its new URL")
    func aWriteAfterTheMoveLandsAtTheNewURL() {
        let library = makeLibrary()
        let instance = RegisteredVMInstanceFixture.register(
            name: "Mover", phase: .stopped, guestOS: .linux, library: library, storage: storage,
            preferences: preferences)
        let original = instance.bundleURL
        let moved = bundleURL("Moved Here")
        storage.moveBundle(from: original, to: moved)
        library.reconcileWithDisk()

        library.editConfiguration(of: instance) { $0.name = "Renamed After Move" }

        #expect(storage.files.configuration(at: moved)?.name == "Renamed After Move")
        #expect(storage.files.configuration(at: original) == nil)
    }

    @Test("A case-only rename keeps its VM, re-bound to the new spelling, with no duplicate report")
    func aCaseOnlyRenameKeepsItsVMReboundToTheNewSpelling() {
        let reports = Reports()
        let library = makeLibrary(reports: reports)
        let instance = RegisteredVMInstanceFixture.register(
            name: "ubuntu", phase: .stopped, guestOS: .linux, library: library, storage: storage,
            preferences: preferences)
        let lowercase = bundleURL("ubuntu")
        storage.moveBundle(from: instance.bundleURL, to: lowercase)
        library.reconcileWithDisk()
        let respelled = lowercase.deletingLastPathComponent()
            .appendingPathComponent("Ubuntu.\(VMBundleFormat.fileExtension)", isDirectory: true)

        // The mock volume folds case, as the default APFS volume does: the old
        // spelling still names the bundle after the rename.
        storage.moveBundle(from: lowercase, to: respelled)
        #expect(library.isSameBundle(lowercase, respelled))
        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first === instance)
        #expect(VMBundleIdentity.spelling(instance.bundleURL) == VMBundleIdentity.spelling(respelled))
        #expect(reports.titles.isEmpty)
    }

    // MARK: - Duplicate Identifiers

    @Test("Two bundles with one identifier at launch produce one VM and one report")
    func twoBundlesWithOneIDAtLaunchProduceOneVMAndOneReport() async {
        let reports = Reports()
        let library = makeLibrary(reports: reports)
        let config = configuration("Twin")
        let first = bundleURL("A Twin")
        let second = bundleURL("B Twin")
        storage.files.seed(
            config, hostState: VMHostState(), snapshots: VMSnapshotManifest(),
            pairings: USBAccessoryPairingSet(), at: second)
        storage.files.seed(
            config, hostState: VMHostState(), snapshots: VMSnapshotManifest(),
            pairings: USBAccessoryPairingSet(), at: first)

        await library.loadVMs()

        #expect(library.instances.count == 1)
        // The winner is the first by bundle name, whatever order the listing
        // answered in.
        #expect(library.instances.first.map { library.isSameBundle($0.bundleURL, first) } == true)
        #expect(reports.titles == ["Duplicate Virtual Machine"])
    }

    @Test("A second bundle with a known identifier at a reconcile is reported once, not adopted")
    func aSecondBundleWithAKnownIDAtReconcileIsReportedOnceNotAdopted() {
        let reports = Reports()
        let library = makeLibrary(reports: reports)
        let instance = RegisteredVMInstanceFixture.register(
            name: "Original", phase: .stopped, guestOS: .linux, library: library,
            storage: storage, preferences: preferences)
        let original = instance.bundleURL
        storage.files.seed(
            instance.configuration, hostState: VMHostState(), snapshots: VMSnapshotManifest(),
            pairings: USBAccessoryPairingSet(), at: bundleURL("Original copy"))

        library.reconcileWithDisk()
        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first === instance)
        #expect(instance.bundleURL == original)
        #expect(reports.titles == ["Duplicate Virtual Machine"])
    }

    // MARK: - Cancel Before the Rename

    @Test("A cancel during the write discards the staged tree and never publishes")
    func aCancelDuringTheWriteDiscardsTheStagedTreeAndNeverPublishes() async throws {
        let library = makeLibrary()
        let gate = GatedStep()
        // A discard that fails still leaves nothing a reconcile can adopt: the
        // staged tree is under the hidden staging directory.
        storage.discardStagedBundleError = CocoaError(.fileWriteNoPermission)

        let arrival = library.beginGatedArrival(named: "Cancelled", gate: gate)
        try await gate.entered.wait { gate.hasEntered }

        #expect(arrival.requestCancel() == .cancelled)
        #expect(arrival.displayLabel == "Cancelling\u{2026}")
        gate.release()
        await #expect(throws: (any Error).self) { try await arrival.settled.value }

        #expect(storage.publishBundleCallCount == 0)
        #expect(storage.discardedStagedURLs == [arrival.stagedURL].compactMap { $0 })
        #expect(library.entries.isEmpty)
        library.reconcileWithDisk()
        #expect(library.entries.isEmpty)
    }

    @Test("A cancel during the rename withdraws the published bundle, and no reconcile adopts it first")
    func aCancelDuringTheRenameWithdrawsThePublishedBundle() async throws {
        let library = makeLibrary()
        let config = configuration("Published")
        let destination = try storage.bundleURL(for: config)
        let decision = Captured<VMArrival.CancelDecision?>(nil)
        let reconciledEntries = Captured<[LibraryEntry]>([])
        let arrivalRef = Captured<VMArrival?>(nil)
        storage.afterPublish = {
            decision.value = arrivalRef.value?.requestCancel()
            library.reconcileWithDisk()
            reconciledEntries.value = library.entries
        }

        let arrival = library.beginArrival(
            kind: .creating, configuration: config, destination: destination,
            write: writing(config))
        arrivalRef.value = arrival
        await #expect(throws: CancellationError.self) { try await arrival.settled.value }

        #expect(decision.value == .withdrawn)
        #expect(reconciledEntries.value.first?.arrival === arrival)
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(storage.bundleIdentity(at: destination) == nil)
        #expect(library.entries.isEmpty)
    }

    @Test("A cancel after the adoption finds nothing left to cancel")
    func aCancelAfterTheAdoptionFindsNothingToCancel() async throws {
        let library = makeLibrary()
        let config = configuration("Adopted")
        let arrival = library.beginArrival(
            kind: .creating, configuration: config,
            destination: try storage.bundleURL(for: config), write: writing(config))
        let instance = try await arrival.settled.value

        #expect(arrival.requestCancel() == .adopted)
        #expect(library.instances.first === instance)
        #expect(storage.deleteVMBundleCallCount == 0)
    }
}
