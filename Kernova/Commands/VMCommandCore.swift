import Foundation
import KernovaKit
import os

/// The headless implementation of every VM verb, beneath the AppKit UI and
/// every automation surface.
///
/// Holds no state of its own — ``VMLibrary`` owns which VMs exist and
/// ``VMLifecycleCoordinator`` owns per-VM operation serialization — so it is
/// deliberately *not* `@Observable`: there is nothing here for a view to watch.
///
/// It presents nothing and imports no AppKit. Anything a user has to see leaves
/// as a thrown ``CommandError`` at the call that caused it, or through
/// ``onFailure`` when no call is waiting; anything a user has to look at leaves
/// through ``surfaceDisplay``.
@MainActor
final class VMCommandCore: VMCommanding {
    nonisolated static let logger = Logger(subsystem: "app.kernova", category: "VMCommandCore")

    // MARK: - Collaborators

    let library: VMLibrary
    let lifecycle: VMLifecycleCoordinator
    let storageService: any VMStorageProviding
    let snapshotStore: any VMSnapshotStoring
    let fileSystem: any FileSystemOperating
    let preferences: AppPreferences

    /// Where every per-VM capability predicate is derived — this core's verb
    /// guards and every surface's enablement read the same one.
    let capabilities: VMCapabilityCatalog

    // MARK: - Adapter Hooks

    /// Puts a VM's display in front of the user — the detached window for a
    /// pop-out or fullscreen VM, keyboard focus in the inline display
    /// otherwise.
    ///
    /// A hook rather than a call: which surface a display lands on is an AppKit
    /// question, and the core answers none.
    var surfaceDisplay: ((VMInstance) -> Void)?

    /// Receives every failure raised with no command call waiting on it — an
    /// Ephemeral baseline revert a power-off started, an external file that
    /// could not be trashed after its VM was deleted, the boot chained off a
    /// finished install.
    ///
    /// Typed rather than flattened to a title and a message, so a failure that
    /// reaches a user this way offers the same recovery it would have offered a
    /// caller — the removable attachment a start failure names, above all.
    var onFailure: ((_ failure: CommandError, _ instance: VMInstance?) -> Void)?

    /// Measures the window or screen a starting VM's display will occupy, for
    /// `displaySizesToWindow`.
    weak var displayBootGeometryProvider: (any DisplayBootGeometryProviding)?

    // MARK: - Observation

    let broadcaster = VMLibraryEventBroadcaster()

    /// The re-arming observation feeding ``broadcaster``, live only while
    /// somebody is reading a stream.
    private var eventLoop: ObservationLoop?

    /// What each VM looked like at the last emission, diffed against the
    /// library to decide what changed.
    private var lastObserved: [UUID: ObservedState] = [:]

    /// The per-VM values ``events()`` reports changes to.
    private struct ObservedState: Equatable {
        let name: String
        let status: VMStatus
        let isPreparing: Bool
        let agentStatus: AgentStatus
        let errorMessage: String?
    }

    // MARK: - Initialization

    init(
        library: VMLibrary,
        lifecycle: VMLifecycleCoordinator,
        storageService: any VMStorageProviding,
        snapshotStore: any VMSnapshotStoring,
        fileSystem: any FileSystemOperating,
        preferences: AppPreferences
    ) {
        self.library = library
        self.lifecycle = lifecycle
        self.storageService = storageService
        self.snapshotStore = snapshotStore
        self.fileSystem = fileSystem
        self.preferences = preferences
        self.capabilities = VMCapabilityCatalog(library: library)

        // An Ephemeral Mode VM goes back to its baseline on every power-off,
        // however it got there — so the handler belongs with the revert verb
        // rather than with whichever surface asked for the stop.
        library.onPoweredOff = { [weak self] instance in
            self?.revertToEphemeralBaselineIfNeeded(instance)
        }
        broadcaster.onSubscriberCountChanged = { [weak self] count in
            self?.reconcileEventLoop(subscriberCount: count)
        }
    }

    // MARK: - Resolution

    /// The one VM `selector` names.
    ///
    /// Display names are not unique, so more than one match is a refusal
    /// carrying every candidate rather than a guess at which was meant.
    func resolve(_ selector: VMSelector) throws -> VMInstance {
        let matches = candidates(for: selector)
        guard let only = matches.first else { throw CommandError.notFound(selector) }
        guard matches.count == 1 else {
            throw CommandError.ambiguous(selector: selector, candidates: matches.map(summary))
        }
        return only
    }

    private func candidates(for selector: VMSelector) -> [VMInstance] {
        switch selector {
        case .id(let id):
            return library.instances.filter { $0.instanceID == id }
        case .name(let name):
            return library.instances.filter { $0.name == name }
        case .idOrName(let text):
            if let id = UUID(uuidString: text) {
                let byID = library.instances.filter { $0.instanceID == id }
                if !byID.isEmpty { return byID }
            }
            return library.instances.filter { $0.name == text }
        }
    }

    /// The wire status a VM copying into place through a clone or import
    /// reports in place of its real ``VMStatus``.
    nonisolated static let preparingWireStatus = "preparing"

    /// `instance`'s status as it crosses the wire — ``preparingWireStatus``
    /// while a clone or import is still copying its bundle, its real
    /// ``VMStatus`` otherwise.
    func wireStatus(_ instance: VMInstance) -> String {
        instance.isPreparing ? Self.preparingWireStatus : instance.status.rawValue
    }

    /// ``ObservedState``'s wire status, by the same rule as ``wireStatus(_:)``.
    private func wireStatus(for state: ObservedState) -> String {
        state.isPreparing ? Self.preparingWireStatus : state.status.rawValue
    }

    func summary(_ instance: VMInstance) -> VMSummary {
        VMSummary(id: instance.instanceID, name: instance.name, status: wireStatus(instance))
    }

    // MARK: - State Gates

    /// The verbs `instance` accepts in the state it is in right now — what an
    /// ``CommandError/invalidState(vm:current:allowed:)`` refusal names.
    ///
    /// A projection of ``VMCapabilityCatalog``, in ``VMCapability``'s
    /// declaration order. Three capabilities carry ``VMVerb/stop``, so the
    /// first one a state admits places it and the rest fall away.
    func allowedVerbs(for instance: VMInstance) -> [VMVerb] {
        var verbs: [VMVerb] = []
        for capability in VMCapability.allCases {
            guard let verb = capability.verb, !verbs.contains(verb),
                capabilities.accepts(capability, on: instance)
            else { continue }
            verbs.append(verb)
        }
        return verbs
    }

    /// Refuses `capability` when `instance` will not take it, naming the copy in
    /// flight when that is what is blocking rather than a status the summary
    /// already reports as `"preparing"`.
    func require(_ capability: VMCapability, on instance: VMInstance) throws {
        try require(anyOf: [capability], on: instance)
    }

    /// Refuses unless `instance` takes at least one of `options` — for the
    /// commands one control reaches through more than one capability, the
    /// suspended VM's Stop that discards its saved state above all.
    func require(anyOf options: [VMCapability], on instance: VMInstance) throws {
        guard !options.contains(where: { capabilities.accepts($0, on: instance) }) else { return }
        throw refusal(for: options, on: instance)
    }

    /// What a refused ``require(anyOf:on:)`` throws: an operation still
    /// settling is what blocks a settle-gated capability, and saying so names
    /// something the user can wait out rather than a status that reads as
    /// eligible.
    private func refusal(for options: [VMCapability], on instance: VMInstance) -> CommandError {
        if instance.preparingState == nil, options.contains(where: \.waitsForSettle),
            library.isBusy(instance)
        {
            return .busy(vm: summary(instance), operation: instance.status.displayName.lowercased())
        }
        return invalidState(instance)
    }

    /// The refusal for a verb the VM's current state does not admit.
    ///
    /// A preparing row's real ``VMStatus`` never explains what is blocking
    /// it — the copy does — so this reports the same ``busy`` refusal
    /// ``refuseIfPreparing(_:)`` throws rather than naming a status the
    /// summary already reports as `"preparing"`, which every caller of this
    /// shared helper inherits without gating individually.
    func invalidState(_ instance: VMInstance) -> CommandError {
        if let state = instance.preparingState {
            return preparingBusyError(instance, state: state)
        }
        return .invalidState(
            vm: summary(instance), current: instance.status,
            allowed: allowedVerbs(for: instance))
    }

    /// Refuses while a clone or import is still writing into the VM's bundle.
    func refuseIfPreparing(_ instance: VMInstance) throws {
        guard let state = instance.preparingState else { return }
        throw preparingBusyError(instance, state: state)
    }

    /// The refusal a verb gets while `instance` is still copying, shared by
    /// ``refuseIfPreparing(_:)`` and ``invalidState(_:)``.
    private func preparingBusyError(
        _ instance: VMInstance, state: VMInstance.PreparingState
    ) -> CommandError {
        .busy(vm: summary(instance), operation: state.operation.displayNoun.lowercased())
    }

    /// Maps an error a lifecycle call threw into the command vocabulary.
    ///
    /// The serialization rejection is the one that carries meaning of its own:
    /// it says the VM already has an operation, which is exactly ``busy``.
    func failure(_ error: Error, verb: VMVerb, on instance: VMInstance) -> CommandError {
        if case VMLifecycleCoordinator.LifecycleError.operationInProgress = error {
            return .busy(
                vm: summary(instance), operation: instance.status.displayName.lowercased())
        }
        return .operationFailed(verb: verb, message: error.localizedDescription)
    }

    // MARK: - Reads

    func list() -> [VMSummary] {
        library.instances.map(summary)
    }

    func info(_ selector: VMSelector) throws -> VMInfo {
        let instance = try resolve(selector)
        let config = instance.configuration
        return VMInfo(
            id: instance.instanceID,
            name: instance.name,
            status: wireStatus(instance),
            guestOS: config.guestOS.rawValue,
            cpuCount: config.cpuCount,
            memoryBytes: config.memorySizeInBytes,
            diskSizeInGB: config.diskSizeInGB,
            networkMode: config.networkEnabled ? config.networkMode.rawValue : nil,
            macAddress: config.macAddress,
            ipAddress: library.reservedAddress(for: config),
            agentStatus: instance.agentStatus.wireName,
            hasSavedState: instance.hasSaveFile,
            isEphemeral: config.ephemeralModeEnabled,
            snapshotCount: instance.snapshotManifest.snapshots.count,
            bundlePath: instance.bundleURL.path(percentEncoded: false)
        )
    }

    func ipAddress(of selector: VMSelector) throws -> String? {
        library.reservedAddress(for: try resolve(selector).configuration)
    }

    func snapshots(of selector: VMSelector) throws -> [SnapshotSummary] {
        let instance = try resolve(selector)
        return instance.snapshotManifest.ordered.map { snapshotSummary($0, on: instance) }
    }

    func snapshotSummary(_ snapshot: VMSnapshot, on instance: VMInstance) -> SnapshotSummary {
        SnapshotSummary(
            id: snapshot.id,
            name: snapshot.name,
            notes: snapshot.notes,
            kind: snapshot.kind.rawValue,
            createdAt: snapshot.createdAt,
            isCurrent: instance.snapshotManifest.currentID == snapshot.id,
            isEphemeralBaseline: instance.isEphemeralBaseline(snapshot)
        )
    }

    // MARK: - Observation

    func events() -> AsyncStream<VMLibraryEvent> {
        broadcaster.stream()
    }

    /// Runs the diffing observation only while somebody is reading a stream.
    private func reconcileEventLoop(subscriberCount: Int) {
        if subscriberCount > 0 {
            guard eventLoop == nil else { return }
            // Seeded before arming, so a fresh subscriber is told what changes
            // from here rather than replayed the library it can already list.
            lastObserved = currentObservedStates()
            eventLoop = observeRecurring(
                track: { [weak self] in self?.trackEventInputs() },
                apply: { [weak self] in self?.emitLibraryChanges() })
        } else {
            eventLoop?.cancel()
            eventLoop = nil
            lastObserved = [:]
        }
    }

    /// Reads every value a ``VMLibraryEvent`` reports, so a change to any of
    /// them wakes the loop.
    private func trackEventInputs() {
        for instance in library.instances {
            _ = instance.configuration.name
            _ = instance.status
            _ = instance.isPreparing
            _ = instance.errorMessage
            _ = instance.agentStatus
        }
    }

    private func currentObservedStates() -> [UUID: ObservedState] {
        var states: [UUID: ObservedState] = [:]
        for instance in library.instances {
            states[instance.instanceID] = ObservedState(
                name: instance.name,
                status: instance.status,
                isPreparing: instance.isPreparing,
                agentStatus: instance.agentStatus,
                errorMessage: instance.errorMessage)
        }
        return states
    }

    /// Emits one event per value that moved since the last pass.
    ///
    /// A diff rather than per-site emission: every verb, every guest-driven
    /// transition, and every reconcile with disk lands in the same model, so
    /// one reader of that model reports them all and no path can forget to.
    /// The cost is coalescing — a VM that passed through `.starting` between
    /// two passes reports only where it ended up.
    private func emitLibraryChanges() {
        let current = currentObservedStates()
        for instance in library.instances {
            let id = instance.instanceID
            guard let now = current[id] else { continue }
            guard let before = lastObserved[id] else {
                broadcaster.emit(
                    .added(VMSummary(id: id, name: now.name, status: wireStatus(for: now))))
                continue
            }
            if before.status != now.status || before.isPreparing != now.isPreparing {
                broadcaster.emit(
                    .statusChanged(
                        id: id, name: now.name, from: wireStatus(for: before),
                        to: wireStatus(for: now)))
                if now.status == .error {
                    broadcaster.emit(
                        .failure(
                            id: id, name: now.name,
                            message: now.errorMessage
                                ?? "The virtual machine stopped with an error."))
                }
            }
            if before.agentStatus != now.agentStatus {
                broadcaster.emit(
                    .agentStatusChanged(
                        id: id, name: now.name, status: now.agentStatus.wireName))
            }
            if before.name != now.name {
                broadcaster.emit(.renamed(id: id, from: before.name, to: now.name))
            }
        }
        for (id, before) in lastObserved where current[id] == nil {
            broadcaster.emit(.removed(id: id, name: before.name))
        }
        lastObserved = current
    }

    // MARK: - Failure Surfacing

    /// Hands a failure that no command call is waiting on to ``onFailure``.
    func report(_ failure: CommandError, on instance: VMInstance?) {
        onFailure?(failure, instance)
    }

    /// Reports a clone or import copy that failed after registering its
    /// preparing row.
    ///
    /// `phantom` is evicted by the time this runs, so the diffing observation
    /// in ``emitLibraryChanges()`` can only ever see it vanish — this message
    /// reaches no observable field and no diff can ever produce it, which is
    /// why it is emitted directly rather than left to the loop.
    func reportPreparingFailure(_ error: Error, verb: VMVerb, phantom: VMInstance) {
        broadcaster.emit(
            .failure(id: phantom.instanceID, name: phantom.name, message: error.localizedDescription))
        report(.operationFailed(verb: verb, message: error.localizedDescription), on: nil)
    }
}
