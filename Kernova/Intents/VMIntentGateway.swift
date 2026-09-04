import AppIntents
import Foundation
import KernovaKit
import os

/// The App Intents front door: everything Siri, Shortcuts, and Spotlight ask of
/// Kernova passes through here and reaches ``VMCommanding``.
///
/// Two things every intent needs, in one place. **Readiness:** an intent can be
/// delivered while the app's first library read is still in flight, and a verb
/// run against a library that has not landed yet refuses with "no virtual
/// machine named…" — so every read and every verb awaits ``ready()`` first.
/// **Addressing:** a ``VMEntity`` already carries the resolved identifier, so
/// this addresses VMs by ``VMSelector/id(_:)`` alone and the ambiguity refusal
/// can never fire from this surface.
///
/// It presents nothing: a refusal leaves as the ``CommandError`` the core threw,
/// which each intent renders in the framework's idiom.
@MainActor
final class VMIntentGateway {
    nonisolated static let logger = Logger(subsystem: "app.kernova", category: "VMIntentGateway")

    private let commands: any VMCommanding
    /// Awaits the app's first library read.
    private let awaitReady: @Sendable () async -> Void
    /// Re-reads the VM names Siri matches spoken phrases against.
    private let refreshShortcutVocabulary: @MainActor () -> Void
    /// Where the library is written for Spotlight to match a spoken name in.
    private let index: any VMEntityIndexing
    /// Called on the main actor whenever the last intent in flight finishes.
    private let onIdle: @MainActor () -> Void

    /// How many intents are executing.
    ///
    /// What holds a process the system launched purely to service an intent:
    /// nothing else is watching one that never opens a window.
    ///
    /// Counted at the ``AppIntent/perform()`` boundary and nowhere else, so it
    /// spans the whole of one intent — the consent round trip and the result
    /// the framework has yet to collect included — and so the reads the system
    /// issues on its own, to resolve a parameter or refresh Siri's vocabulary,
    /// are not counted at all. Those arrive unbidden, in volume, and counting
    /// one would report the process idle before the intent it was resolving for
    /// had been delivered.
    private var intentsInFlight = 0

    /// Whether any intent is executing.
    var hasIntentInFlight: Bool { intentsInFlight > 0 }

    /// The single readiness await, memoized so an intent storm waits on one task.
    private var readiness: Task<Void, Never>?
    /// The library subscription that keeps Siri's vocabulary and the Spotlight
    /// index current.
    private var libraryEvents: Task<Void, Never>?

    init(
        commands: any VMCommanding,
        awaitReady: @escaping @Sendable () async -> Void,
        refreshShortcutVocabulary: @escaping @MainActor () -> Void = {
            KernovaShortcuts.updateAppShortcutParameters()
        },
        index: any VMEntityIndexing = SpotlightVMEntityIndex(),
        onIdle: @escaping @MainActor () -> Void = {}
    ) {
        self.commands = commands
        self.awaitReady = awaitReady
        self.refreshShortcutVocabulary = refreshShortcutVocabulary
        self.index = index
        self.onIdle = onIdle
        // Weakly, one main-actor call at a time: an owner that goes away
        // between two batches is what ends the subscription.
        libraryEvents = Task { [weak self] in
            guard let batches = await self?.subscribeOnceReady() else { return }
            await self?.syncWholeLibrary()
            for await batch in batches {
                await self?.apply(batch)
            }
        }
    }

    deinit {
        libraryEvents?.cancel()
    }

    // MARK: - Readiness

    /// Returns once the app's first library read has landed.
    func ready() async {
        if let readiness {
            await readiness.value
            return
        }
        let task = Task { [awaitReady] in await awaitReady() }
        readiness = task
        await task.value
    }

    // MARK: - In-Flight Accounting

    /// Marks one intent as executing, holding the process open.
    ///
    /// Every ``AppIntent/perform()`` calls this first and pairs it with
    /// ``endIntent()`` in a `defer`, which is what makes the hold span the
    /// whole intent rather than one gateway call: a destructive verb's refusal
    /// returns here long before `requestConfirmation` has asked the question,
    /// and a read's value is built after its call has returned. Releasing at
    /// either point would let the process quit mid-intent — and `NSApp.terminate`
    /// does not come back.
    func beginIntent() {
        intentsInFlight += 1
    }

    /// Marks one intent as finished, reporting the process idle when it was the
    /// last.
    ///
    /// The report is deferred to a later main-actor turn and re-tests the count,
    /// so the result the intent just built reaches the framework first and a
    /// second intent arriving in between cancels it.
    func endIntent() {
        intentsInFlight -= 1
        guard intentsInFlight == 0 else { return }
        Task { @MainActor [weak self] in
            guard let self, self.intentsInFlight == 0 else { return }
            self.onIdle()
        }
    }

    // MARK: - Reads

    /// Every VM in the library, each read in full.
    ///
    /// A ``VMEntity`` carries the whole `info` read, so the listing pairs each
    /// row with its own. Both calls are synchronous main-actor reads of state
    /// already in memory, with no suspension between them — a row that lists
    /// and then fails to read is a programming error, not a race, so it is
    /// asserted and skipped rather than being taken for a VM that left.
    func vms() async -> [VMEntity] {
        await ready()
        return commands.list().compactMap { summary in
            do {
                return VMEntity(try commands.info(.id(summary.id)))
            } catch {
                Self.logger.fault(
                    "Listed VM \(summary.id.uuidString, privacy: .public) has no info read: \(error.localizedDescription, privacy: .public)"
                )
                assertionFailure("Listed VM \(summary.id.uuidString) has no info read: \(error)")
                return nil
            }
        }
    }

    /// The VMs `ids` names, in library order, skipping any that have since left.
    func vms(withIDs ids: [UUID]) async -> [VMEntity] {
        let wanted = Set(ids)
        return await vms().filter { wanted.contains($0.id) }
    }

    /// Every VM whose name contains `text`, matched the way a person says it
    /// rather than the way the core's `.name` selector matches — a spoken
    /// "start sonoma" has neither the case nor the whole of the display name.
    func vms(matching text: String) async -> [VMEntity] {
        await vms().filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    func info(_ id: UUID) async throws -> VMInfo {
        try await perform(.info, on: id) { try self.commands.info(.id(id)) }
    }

    func ipAddress(of id: UUID) async throws -> String? {
        try await perform(.ipAddress, on: id) { try self.commands.ipAddress(of: .id(id)) }
    }

    /// The VM's named restore points, newest first.
    func snapshots(ofVM id: UUID) async throws -> [SnapshotEntity] {
        try await perform(.snapshots, on: id) {
            try self.commands.snapshots(of: .id(id)).map { SnapshotEntity($0, vm: id) }
        }
    }

    // MARK: - Lifecycle

    func start(_ id: UUID, recovery: Bool) async throws {
        try await perform(.start, on: id) {
            try await self.commands.start(.id(id), recovery: recovery)
        }
    }

    func stop(_ id: UUID, disposition: StopDisposition, confirmed: Bool) async throws {
        try await perform(.stop, on: id) {
            try await self.commands.stop(
                .id(id), disposition: disposition, confirmed: confirmed)
        }
    }

    func pause(_ id: UUID) async throws {
        try await perform(.pause, on: id) { try await self.commands.pause(.id(id)) }
    }

    func resume(_ id: UUID) async throws {
        try await perform(.resume, on: id) { try await self.commands.resume(.id(id)) }
    }

    func suspend(_ id: UUID) async throws {
        try await perform(.suspend, on: id) { try await self.commands.suspend(.id(id)) }
    }

    func restart(_ id: UUID) async throws {
        try await perform(.restart, on: id) { try await self.commands.restart(.id(id)) }
    }

    func open(_ id: UUID) async throws {
        try await perform(.open, on: id) { try self.commands.open(.id(id)) }
    }

    func cancelGuestSetup(_ id: UUID, confirmed: Bool) async throws {
        try await perform(.cancelGuestSetup, on: id) {
            try self.commands.cancelGuestSetup(.id(id), confirmed: confirmed)
        }
    }

    // MARK: - Snapshots

    @discardableResult
    func takeSnapshot(_ id: UUID, name: String, notes: String) async throws -> SnapshotSummary {
        try await perform(.takeSnapshot, on: id) {
            try await self.commands.takeSnapshot(.id(id), name: name, notes: notes)
        }
    }

    func revertToSnapshot(
        _ id: UUID, snapshot: SnapshotEntityID, takingCheckpoint: Bool, confirmed: Bool
    ) async throws {
        try await perform(.revertToSnapshot, on: id) {
            let listed = try self.listedSnapshot(snapshot, on: id, verb: .revertToSnapshot)
            try await self.commands.revertToSnapshot(
                .id(id), snapshot: listed, takingCheckpoint: takingCheckpoint,
                confirmed: confirmed)
        }
    }

    func deleteSnapshot(_ id: UUID, snapshot: SnapshotEntityID, confirmed: Bool) async throws {
        try await perform(.deleteSnapshot, on: id) {
            let listed = try self.listedSnapshot(snapshot, on: id, verb: .deleteSnapshot)
            try await self.commands.deleteSnapshot(
                .id(id), snapshot: listed, confirmed: confirmed)
        }
    }

    func renameSnapshot(_ id: UUID, snapshot: SnapshotEntityID, to newName: String) async throws {
        try await perform(.renameSnapshot, on: id) {
            let listed = try self.listedSnapshot(snapshot, on: id, verb: .renameSnapshot)
            try self.commands.renameSnapshot(.id(id), snapshot: listed, to: newName)
        }
    }

    func setSnapshotNotes(_ id: UUID, snapshot: SnapshotEntityID, notes: String) async throws {
        try await perform(.setSnapshotNotes, on: id) {
            let listed = try self.listedSnapshot(snapshot, on: id, verb: .setSnapshotNotes)
            try self.commands.setSnapshotNotes(.id(id), snapshot: listed, notes: notes)
        }
    }

    /// The snapshot `picked` names, refusing one belonging to another VM.
    ///
    /// The VM parameter is authoritative — a Shortcut that changes it after
    /// picking a snapshot must not act on the VM the stale pick names — and
    /// this is where that is enforced for every snapshot verb, not only the
    /// ones the core happens to catch. A revert or delete would be refused
    /// there anyway; a rename or a note edit would not, because both are
    /// documented no-ops for an identifier the manifest does not list, so the
    /// mismatch would report success having changed nothing.
    private func listedSnapshot(
        _ picked: SnapshotEntityID, on vm: UUID, verb: VMVerb
    ) throws -> UUID {
        guard picked.vm != vm else { return picked.snapshot }
        let name = (try? commands.info(.id(vm)).name) ?? vm.uuidString
        throw CommandError.operationFailed(
            verb: verb,
            message:
                "\u{201C}\(name)\u{201D} has no snapshot with the identifier \(picked.snapshot.uuidString)."
        )
    }

    // MARK: - Library

    /// Copies the VM's bundle, answering the row the copy fills.
    ///
    /// The clone registers its phantom row before returning and the `info` read
    /// is the same main-actor turn, so the row is always there to describe.
    func clone(_ id: UUID, machineIdentity: CloneMachineIdentity) async throws -> VMEntity {
        try await perform(.clone, on: id) {
            let copy = try self.commands.clone(.id(id), machineIdentity: machineIdentity)
            return VMEntity(try self.commands.info(.id(copy.id)))
        }
    }

    func rename(_ id: UUID, to newName: String) async throws {
        try await perform(.rename, on: id) { try self.commands.rename(.id(id), to: newName) }
    }

    /// Moves the VM's bundle to the Trash.
    ///
    /// The permanent delete and the external files a delete can also remove are
    /// both left to the app's own sheet: one is a user-confirmed exception to
    /// the project's file-deletion rule, and the other names files this surface
    /// never showed the user.
    func delete(_ id: UUID, confirmed: Bool) async throws {
        try await perform(.delete, on: id) {
            try await self.commands.delete(
                .id(id), permanently: false, alsoRemoving: [], confirmed: confirmed)
        }
    }

    func cancelPreparing(_ id: UUID, confirmed: Bool) async throws {
        try await perform(.cancelPreparing, on: id) {
            try self.commands.cancelPreparing(.id(id), confirmed: confirmed)
        }
    }

    // MARK: - Dispatch

    /// Runs `verb` once the library read has landed, logging any refusal.
    ///
    /// The log line is the only trace an App Intents failure leaves: the
    /// framework shows it to whoever ran the intent and reports it nowhere
    /// else — no alert, no window, nothing a later session can read back.
    private func perform<T>(
        _ verb: VMVerb, on id: UUID, _ body: () async throws -> T
    ) async throws -> T {
        await ready()
        do {
            return try await body()
        } catch let failure as CommandError {
            Self.logger.notice(
                "Intent \(verb.rawValue, privacy: .public) refused for \(id.uuidString, privacy: .public): \(failure.message, privacy: .public)"
            )
            throw failure
        }
    }

    // MARK: - Library Tracking

    /// Subscribes to library changes once the app's first read has landed.
    ///
    /// The subscription is taken on the turn readiness resolves on, with
    /// nothing awaited in between: the core seeds its diff from the library as
    /// it stands when the first subscriber arrives, so subscribing behind the
    /// first read leaves the load itself emitting nothing — which is what
    /// ``syncWholeLibrary()`` then covers.
    private func subscribeOnceReady() async -> AsyncStream<[VMLibraryEvent]> {
        await ready()
        return commands.events()
    }

    /// Rebuilds Siri's vocabulary and rewrites every VM into the index,
    /// replacing whatever an earlier run of the app left there.
    private func syncWholeLibrary() async {
        rebuildVocabulary()
        let all = await vms()
        await write("clearing the VM index") { try await self.index.removeAll() }
        await write("indexing every VM") { try await self.index.index(all) }
    }

    /// Brings Siri's vocabulary and the index up to what one pass over the
    /// library found, ignoring the changes neither surface shows.
    ///
    /// One batch is one rebuild and at most one write of each kind. A rebuild
    /// spends one of the system's donation-rate tokens, so a library big
    /// enough to spend them one VM at a time would leave Siri matching stale
    /// names for the rest of the session.
    private func apply(_ batch: [VMLibraryEvent]) async {
        var present: [UUID] = []
        var absent: [UUID] = []
        for event in batch {
            switch event {
            case .added(let summary): present.append(summary.id)
            case .renamed(let id, _, _): present.append(id)
            case .removed(let id, _): absent.append(id)
            case .statusChanged, .agentStatusChanged, .failure: break
            }
        }
        guard !present.isEmpty || !absent.isEmpty else { return }
        rebuildVocabulary()
        if !absent.isEmpty {
            await write("removing \(absent.count) VMs from the index") {
                try await self.index.remove(absent)
            }
        }
        if !present.isEmpty {
            let entities = await vms(withIDs: present)
            await write("indexing \(entities.count) VMs") {
                try await self.index.index(entities)
            }
        }
    }

    private func rebuildVocabulary() {
        Self.logger.debug("Rebuilding App Shortcut parameter vocabulary")
        refreshShortcutVocabulary()
    }

    /// Runs one index write, logging and swallowing a refusal.
    ///
    /// Spotlight is how a spoken name is matched, never how a verb runs: a
    /// refusal must neither fail an intent nor end the subscription that would
    /// carry the next write.
    private func write(_ operation: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            Self.logger.warning(
                "Spotlight failed \(operation, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
