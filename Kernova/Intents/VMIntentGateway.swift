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
        }
    ) {
        self.commands = commands
        self.awaitReady = awaitReady
        self.refreshShortcutVocabulary = refreshShortcutVocabulary
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

    // MARK: - Reads

    func vms() async -> [VMEntity] {
        await ready()
        return commands.list().map(VMEntity.init)
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
        await ready()
        return try commands.info(.id(id))
    }

    func ipAddress(of id: UUID) async throws -> String? {
        await ready()
        return try commands.ipAddress(of: .id(id))
    }

    // MARK: - Lifecycle

    func start(_ id: UUID, recovery: Bool) async throws {
        await ready()
        try await commands.start(.id(id), recovery: recovery)
    }

    func stop(_ id: UUID, disposition: StopDisposition, confirmed: Bool) async throws {
        await ready()
        try await commands.stop(.id(id), disposition: disposition, confirmed: confirmed)
    }

    func pause(_ id: UUID) async throws {
        await ready()
        try await commands.pause(.id(id))
    }

    func resume(_ id: UUID) async throws {
        await ready()
        try await commands.resume(.id(id))
    }

    func suspend(_ id: UUID) async throws {
        await ready()
        try await commands.suspend(.id(id))
    }

    func restart(_ id: UUID) async throws {
        await ready()
        try await commands.restart(.id(id))
    }

    func open(_ id: UUID) async throws {
        await ready()
        try commands.open(.id(id))
    }

    // MARK: - Snapshots

    @discardableResult
    func takeSnapshot(_ id: UUID, name: String, notes: String) async throws -> SnapshotSummary {
        await ready()
        return try await commands.takeSnapshot(.id(id), name: name, notes: notes)
    }

    // MARK: - Shortcut Vocabulary

    private func markVocabularyStale() {
        guard !isVocabularyStale else { return }
        isVocabularyStale = true
        Task { @MainActor [weak self] in
            guard let self, self.isVocabularyStale else { return }
            self.isVocabularyStale = false
            self.refreshShortcutVocabulary()
        }
    }
}
