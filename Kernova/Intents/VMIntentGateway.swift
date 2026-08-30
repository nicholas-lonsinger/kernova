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
    /// Called on the main actor whenever the last intent in flight finishes.
    private let onIdle: @MainActor () -> Void

    /// How many intents are executing.
    ///
    /// What holds a process the system launched purely to service an intent:
    /// nothing else is watching one that never opens a window. Deliberately
    /// counts only intent execution — the ``VMEntityQuery`` reads the system
    /// issues on its own to refresh Siri's vocabulary are *not* counted, because
    /// they arrive unbidden and would otherwise report the process idle before
    /// the intent that launched it had even been delivered.
    private var intentsInFlight = 0

    /// The single readiness await, memoized so an intent storm waits on one task.
    private var readiness: Task<Void, Never>?
    /// The library subscription that keeps Siri's VM vocabulary current.
    private var libraryEvents: Task<Void, Never>?
    /// Set when an event changed which VMs exist or what they are called, and
    /// drained on the next main-actor turn — a batch import emits one event per
    /// VM and the vocabulary only needs rebuilding once.
    private var isVocabularyStale = false

    init(
        commands: any VMCommanding,
        awaitReady: @escaping @Sendable () async -> Void,
        refreshShortcutVocabulary: @escaping @MainActor () -> Void = {
            KernovaShortcuts.updateAppShortcutParameters()
        },
        onIdle: @escaping @MainActor () -> Void = {}
    ) {
        self.commands = commands
        self.awaitReady = awaitReady
        self.refreshShortcutVocabulary = refreshShortcutVocabulary
        self.onIdle = onIdle
        libraryEvents = Task { [weak self] in
            guard let stream = self?.commands.events() else { return }
            for await event in stream {
                guard let self else { return }
                switch event {
                case .added, .removed, .renamed:
                    self.markVocabularyStale()
                case .statusChanged, .agentStatusChanged, .failure:
                    break
                }
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

    /// Runs `body` as one intent, reporting the process idle when it is the last
    /// one to finish.
    ///
    /// The idle report is what an automation-launched process is waiting for to
    /// decide whether to stay resident or leave, so it fires on the way out of
    /// every path — a refusal included.
    private func asIntent<T>(_ body: () async throws -> T) async rethrows -> T {
        intentsInFlight += 1
        defer {
            intentsInFlight -= 1
            if intentsInFlight == 0 { onIdle() }
        }
        return try await body()
    }

    // MARK: - Reads

    /// Every VM in the library, answering the *Find Virtual Machines* intent.
    ///
    /// Separate from ``vms()``, which the entity query shares: this is intent
    /// execution and holds the process, that is the system reading vocabulary
    /// and does not.
    func listVMs() async -> [VMEntity] {
        await asIntent { await vms() }
    }

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
        try await asIntent {
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
    }

    // MARK: - Shortcut Vocabulary

    private func markVocabularyStale() {
        guard !isVocabularyStale else { return }
        isVocabularyStale = true
        Task { @MainActor [weak self] in
            guard let self, self.isVocabularyStale else { return }
            self.isVocabularyStale = false
            Self.logger.debug("Rebuilding App Shortcut parameter vocabulary")
            self.refreshShortcutVocabulary()
        }
    }
}
