import Foundation
import KernovaKit
import KernovaLogging

/// The headless implementation of every VM verb, beneath the AppKit UI and
/// every automation surface.
///
/// Holds no VM state of its own — ``VMLibrary`` owns which VMs exist and
/// ``VMLifecycleCoordinator`` owns per-VM operation serialization — so it is
/// *not* `@Observable`: there is nothing here for a view to watch.
///
/// It presents nothing and imports no AppKit. Anything a user has to see leaves
/// as a thrown ``CommandError`` at the call that caused it, or through
/// ``onFailure`` when no call is waiting; anything a user has to look at leaves
/// through ``surfaceDisplay``, ``readyDisplay`` or ``revealInLibrary``.
@MainActor
final class VMCommandCore: VMCommanding {
    nonisolated static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMCommandCore")

    // MARK: - Collaborators

    let library: VMLibrary
    let lifecycle: VMLifecycleCoordinator
    let storageService: any VMStorageProviding
    let diskImageService: any DiskImageProviding
    let fileSystem: any FileSystemOperating
    let preferences: AppPreferences

    /// What a bounded wait for a guest to power off measures itself against —
    /// injected so a test crosses the deadline in one call rather than sleeping
    /// through it.
    let clock: any EngineClock

    /// Where every per-VM capability predicate is derived — this core's verb
    /// guards and every surface's enablement read the same one.
    var capabilities: VMCapabilityCatalog { library.capabilities }

    // MARK: - Adapter Hooks

    /// Puts a VM's display in front of the user — the detached window for a
    /// pop-out or fullscreen VM, keyboard focus in the inline display
    /// otherwise, with the library brought forward to carry it.
    ///
    /// A hook rather than a call: which surface a display lands on is an AppKit
    /// question, and the core answers none.
    var surfaceDisplay: ((VMInstance) -> Void)?

    /// Reports that a VM is coming up, so its display can be readied to receive
    /// the guest.
    ///
    /// Asked on every bring-up, whoever asked for it. Whether anything is put
    /// on screen is the adapter's decision, taken from the app's own posture —
    /// a bring-up is not a request to look at the guest, which is what
    /// ``surfaceDisplay`` carries.
    var readyDisplay: ((VMInstance) -> Void)?

    /// Puts a library row with no display to surface in front of the user —
    /// a VM's or an arrival's, by identifier — with the library itself brought
    /// forward.
    ///
    /// A hook rather than a call, for the reason ``surfaceDisplay`` states —
    /// and a second hook rather than a flag on that one, because the two land
    /// on different surfaces and only the adapter knows either.
    var revealInLibrary: ((UUID) -> Void)?

    /// Selects a VM's bundle in the Finder, bringing the Finder forward.
    ///
    /// A hook rather than a call, for the reason ``surfaceDisplay`` states:
    /// what a file lands in front of the user through is an AppKit question.
    var revealInFinder: ((VMInstance) -> Void)?

    /// Receives every failure raised with no command call waiting on it — an
    /// Ephemeral baseline revert a power-off started, an external file that
    /// could not be trashed after its VM was deleted, the boot chained off a
    /// finished install, a create, clone or import nobody waits on.
    ///
    /// Typed rather than flattened to a title and a message, so a failure that
    /// reaches a user this way offers the same recovery it would have offered a
    /// caller — the removable attachment a start failure names, above all.
    var onFailure: ((_ failure: CommandError, _ instance: VMInstance?) -> Void)?

    /// Turns a path an out-of-process client named into a URL this sandboxed
    /// process may read.
    ///
    /// A hook rather than a call, for the reason ``surfaceDisplay`` states: the
    /// grant comes from an open panel, and the core presents none. Only the two
    /// verbs that take a path from a client with no file access of its own —
    /// the import and the shared-directory add — consult it.
    var sourceAuthority: (any SandboxSourceAuthorizing)?

    /// Takes the app down the way the status item's Quit does.
    ///
    /// A hook rather than a call, for the reason ``surfaceDisplay`` states: the
    /// quit is an AppKit termination, and the core performs none.
    var requestQuit: (() -> Void)?

    /// Reports an accessory the user has just placed on a guest, so that guest
    /// takes it back on its own from now on.
    ///
    /// A hook rather than a call: what an attach *means* for the future is the
    /// accessory coordinator's policy, and a build that cannot pass accessories
    /// through has no coordinator to hold it.
    var onUserAttachedAccessory: ((VMInstance, USBAccessoryInfo) throws -> Void)?

    /// Reports an accessory the user is about to take back by hand, before the
    /// detach runs: the detach re-enumerates the device, and the return it
    /// causes can arrive while the detach is still in flight.
    ///
    /// Not fired by the lifecycle's own eject sweeps, and neither is
    /// ``onUserReleasedAccessory``: a stop, a suspend or a snapshot capture
    /// takes an accessory off without the user asking, and must leave the
    /// pairing alone.
    var onUserDetachingAccessory: ((VMInstance, USBAccessoryInfo) -> Void)?

    /// Reports an accessory the user has just taken back by hand, which ends
    /// that pairing.
    var onUserReleasedAccessory: ((VMInstance, USBAccessoryInfo) throws -> Void)?

    /// Measures the window or screen a starting VM's display is about to occupy,
    /// for `displaySizesToWindow` — `nil` when nothing can measure one.
    ///
    /// A hook rather than a call, for the reason ``surfaceDisplay`` states: what
    /// a display will land on is an AppKit question.
    var displayBootSurface: ((VMInstance) -> DisplayBootSurface?)?

    #if DEBUG
    /// Runs right after an attachment removal resolves sharing off-main — in
    /// place of whatever a user does through the still-live menu key
    /// equivalents while that resolve is in flight.
    var afterSharingResolveForTesting: (@MainActor () async -> Void)?
    #endif

    // MARK: - Observation

    let broadcaster = VMLibraryEventBroadcaster()

    /// The re-arming observation feeding ``broadcaster``, live only while
    /// somebody is reading a stream.
    private var eventLoop: ObservationLoop?

    /// What each row looked like at the last emission, diffed against the
    /// library to decide what changed.
    private var lastObserved: [UUID: ObservedState] = [:]

    /// The per-row values ``events()`` reports changes to.
    private struct ObservedState: Equatable {
        let name: String
        /// `nil` for an arrival, which has no ``VMStatus`` yet.
        let status: VMStatus?
        let agentStatus: AgentStatus
        let errorMessage: String?

        /// The status as it crosses the wire.
        var wireStatus: String { status?.rawValue ?? VMStatus.preparingWireName }
    }

    // MARK: - Initialization

    init(
        library: VMLibrary,
        lifecycle: VMLifecycleCoordinator,
        storageService: any VMStorageProviding,
        diskImageService: any DiskImageProviding,
        fileSystem: any FileSystemOperating,
        preferences: AppPreferences,
        clock: any EngineClock = makePlatformEngineClock()
    ) {
        self.library = library
        self.lifecycle = lifecycle
        self.storageService = storageService
        self.diskImageService = diskImageService
        self.fileSystem = fileSystem
        self.preferences = preferences
        self.clock = clock

        // An Ephemeral Mode VM goes back to its baseline on every power-off,
        // however it got there — so the handler belongs with the revert verb
        // rather than with whichever surface asked for the stop.
        library.onPoweredOff = { [weak self] instance in
            self?.revertToEphemeralBaselineIfNeeded(instance)
        }
        // The installer disk comes out the moment the agent it carries
        // handshakes as current, whichever surface asked for the mount — so the
        // handler belongs with the guest-agent-disk verb rather than with any
        // of them.
        library.onAgentBecameCurrent = { [weak self] instance in
            self?.detachGuestAgentDisk(from: instance)
        }
        library.onArrivalFailed = { [weak self] arrival, error in
            self?.arrivalFailed(arrival, with: error)
        }
        broadcaster.onSubscriberCountChanged = { [weak self] count in
            self?.reconcileEventLoop(subscriberCount: count)
        }
    }

    // MARK: - Resolution

    /// The one library row `selector` names, a VM's or an arrival's.
    ///
    /// Display names are not unique, so more than one match is a refusal
    /// carrying every candidate rather than a guess at which was meant.
    func resolveEntry(_ selector: VMSelector) throws -> LibraryEntry {
        let matches = candidates(for: selector)
        guard let only = matches.first else { throw CommandError.notFound(selector) }
        guard matches.count == 1 else {
            throw CommandError.ambiguous(selector: selector, candidates: matches.map(summary))
        }
        return only
    }

    /// The one VM `selector` names; an arrival it names is refused as busy
    /// with its create, clone or import.
    func resolve(_ selector: VMSelector) throws -> VMInstance {
        switch try resolveEntry(selector) {
        case .vm(let instance): instance
        case .arriving(let arrival): throw busy(arrival)
        }
    }

    private func candidates(for selector: VMSelector) -> [LibraryEntry] {
        let entries = library.entries
        switch selector {
        case .id(let id):
            return entries.filter { $0.id == id }
        case .name(let name):
            return entries.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        case .idOrName(let text):
            if let id = UUID(uuidString: text) {
                let byID = entries.filter { $0.id == id }
                if !byID.isEmpty { return byID }
            }
            return entries.filter { $0.name.caseInsensitiveCompare(text) == .orderedSame }
        }
    }

    /// The refusal every VM verb addressed to an arrival raises.
    func busy(_ arrival: VMArrival) -> CommandError {
        .busy(vm: summary(arrival), operation: arrival.kind.displayNoun.lowercased())
    }

    func summary(_ instance: VMInstance) -> VMSummary {
        instance.summary(
            ipAddress: library.guestAddresses.address(for: instance))
    }

    /// An arrival as a listing names it: ``VMStatus/preparingWireName``, and
    /// the address its configuration answers with nothing live.
    func summary(_ arrival: VMArrival) -> VMSummary {
        VMSummary(
            id: arrival.id, name: arrival.name, status: VMStatus.preparingWireName,
            ipAddress: GuestAddressObserver.address(withNoLiveGuest: arrival.configuration))
    }

    func summary(_ entry: LibraryEntry) -> VMSummary {
        switch entry {
        case .vm(let instance): summary(instance)
        case .arriving(let arrival): summary(arrival)
        }
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

    /// Refuses `capability` when `instance` will not take it.
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
    ///
    /// Internal because a caller that decided a capability's fate somewhere
    /// other than ``require(anyOf:on:)`` still owes the user the refusal that
    /// verb would have raised.
    func refusal(for options: [VMCapability], on instance: VMInstance) -> CommandError {
        if options.contains(where: \.locksWhileCloned), library.hasCloneInFlight(from: instance) {
            return .busy(vm: summary(instance), operation: "being cloned")
        }
        if options.contains(where: \.waitsForSettle), library.isBusy(instance) {
            return .busy(vm: summary(instance), operation: instance.status.displayName.lowercased())
        }
        return invalidState(instance)
    }

    /// The refusal for a verb the VM's current state does not admit.
    func invalidState(_ instance: VMInstance) -> CommandError {
        .invalidState(
            vm: summary(instance), current: instance.status,
            allowed: allowedVerbs(for: instance))
    }

    /// The refusal for something the verb named on a VM that has no such thing
    /// — a snapshot identifier, an attachment identifier.
    ///
    /// A refusal, not a failure: the verb never ran, so it answers the way an
    /// unknown VM name does rather than the way a verb that ran and did not
    /// finish does.
    func itemNotFound(_ instance: VMInstance, item: String) -> CommandError {
        .itemNotFound(vm: summary(instance), item: item)
    }

    /// The authority for a path a client named, or the refusal a process that
    /// never wired one owes.
    func requireSourceAuthority(_ verb: VMVerb) throws -> any SandboxSourceAuthorizing {
        guard let sourceAuthority else {
            #log(
                Self.logger, .fault,
                "No sandbox source authority is wired; \(String(describing: verb), privacy: .public) cannot reach a named path"
            )
            assertionFailure("No sandbox source authority is wired for \(verb)")
            throw CommandError.operationFailed(
                verb: verb,
                message: "Kernova cannot ask for permission to read that file right now.")
        }
        return sourceAuthority
    }

    /// Throws unless `write` landed whole.
    ///
    /// The one write convention every verb in the core shares: a change that
    /// was refused changes nothing, and one whose save failed says whether
    /// part of it landed.
    func requireSaved(_ write: VMLibrary.SettingsWrite, of instance: VMInstance, verb: VMVerb)
        throws
    {
        switch write {
        case .saved:
            return
        case .refused(let refusal):
            throw refusalError(refusal, on: instance)
        case .notSaved(let failure):
            throw CommandError.operationFailed(
                verb: verb,
                message: failure.landed.isEmpty
                    ? "The change to \u{201C}\(instance.name)\u{201D} was not saved."
                    : "The change to \u{201C}\(instance.name)\u{201D} was saved only in part: its configuration changed, but Kernova\u{2019}s own settings for it did not."
            )
        }
    }

    /// Applies `mutate` to what the VM's `config.json` holds, throwing unless
    /// it landed (``requireSaved(_:of:verb:)``).
    func writeConfiguration(
        of instance: VMInstance, verb: VMVerb, _ mutate: (inout VMConfiguration) -> Void
    ) throws {
        try requireSaved(
            library.updateConfiguration(of: instance, mutate: mutate), of: instance, verb: verb)
    }

    /// The refusal a verb raises when the library turned its settings write
    /// away.
    func refusalError(
        _ refusal: VMLibrary.SettingsRefusal, on instance: VMInstance
    ) -> CommandError {
        switch refusal {
        case .macAddressInUse(let conflict):
            .conflict(vm: summary(instance), with: summary(conflict.other), reason: conflict.reason)
        case .sessionNotAttachable:
            invalidState(instance)
        case .noLibrary:
            .notFound(.id(instance.id))
        }
    }

    /// Maps an error a lifecycle call threw into the command vocabulary.
    ///
    /// Two carry meaning of their own: the serialization rejection says the VM
    /// already has an operation, which is exactly ``busy``, and a bring-up
    /// refused over another live VM's identity is a ``conflict``.
    func failure(_ error: Error, verb: VMVerb, on instance: VMInstance) -> CommandError {
        if case VMLifecycleCoordinator.LifecycleError.operationInProgress = error {
            return .busy(
                vm: summary(instance), operation: instance.status.displayName.lowercased())
        }
        if let conflict = error as? VMIdentityConflict {
            return .conflict(
                vm: summary(instance), with: summary(conflict.other),
                reason: conflict.reason.conflictReason)
        }
        return .operationFailed(verb: verb, message: error.localizedDescription)
    }

    // MARK: - Reads

    func list() -> [VMSummary] {
        library.entries.map(summary)
    }

    func info(_ selector: VMSelector) throws -> VMInfo {
        switch try resolveEntry(selector) {
        case .vm(let instance): info(instance)
        case .arriving(let arrival): info(arrival)
        }
    }

    private func info(_ instance: VMInstance) -> VMInfo {
        let config = instance.configuration
        return VMInfo(
            id: instance.instanceID,
            name: instance.name,
            status: instance.status.rawValue,
            guestOS: config.guestOS.rawValue,
            cpuCount: config.cpuCount,
            memoryBytes: config.memorySizeInBytes,
            diskSizeInGB: config.diskSizeInGB,
            networkMode: config.networkEnabled ? config.networkMode.rawValue : nil,
            macAddress: config.macAddress,
            ipAddress: library.guestAddresses.address(for: instance),
            agentStatus: instance.agentStatus.wireName,
            hasSavedState: instance.hasSaveFile,
            isEphemeral: instance.hostState.ephemeralModeEnabled,
            snapshotCount: instance.snapshotManifest.snapshots.count,
            bundlePath: instance.bundleURL.path(percentEncoded: false)
        )
    }

    /// An arrival described from what its write was asked for: no session, no
    /// saved state, no snapshots, and the bundle path it publishes at.
    private func info(_ arrival: VMArrival) -> VMInfo {
        let config = arrival.configuration
        return VMInfo(
            id: arrival.id,
            name: arrival.name,
            status: VMStatus.preparingWireName,
            guestOS: config.guestOS.rawValue,
            cpuCount: config.cpuCount,
            memoryBytes: config.memorySizeInBytes,
            diskSizeInGB: config.diskSizeInGB,
            networkMode: config.networkEnabled ? config.networkMode.rawValue : nil,
            macAddress: config.macAddress,
            ipAddress: GuestAddressObserver.address(withNoLiveGuest: config),
            agentStatus: AgentStatus.waiting.wireName,
            hasSavedState: false,
            isEphemeral: false,
            snapshotCount: 0,
            bundlePath: arrival.destinationURL.path(percentEncoded: false)
        )
    }

    func ipAddress(of selector: VMSelector) throws -> GuestIPAddress {
        library.guestAddresses.address(for: try resolve(selector))
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

    func events() -> AsyncStream<[VMLibraryEvent]> {
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
        for entry in library.entries {
            guard case .vm(let instance) = entry else { continue }
            _ = instance.configuration.name
            _ = instance.status
            _ = instance.errorMessage
            _ = instance.agentStatus
        }
    }

    private func currentObservedStates() -> [UUID: ObservedState] {
        var states: [UUID: ObservedState] = [:]
        for entry in library.entries {
            switch entry {
            case .vm(let instance):
                states[instance.instanceID] = ObservedState(
                    name: instance.name,
                    status: instance.status,
                    agentStatus: instance.agentStatus,
                    errorMessage: instance.errorMessage)
            case .arriving(let arrival):
                states[arrival.id] = ObservedState(
                    name: arrival.name, status: nil, agentStatus: .waiting, errorMessage: nil)
            }
        }
        return states
    }

    /// Emits one batch carrying every value that moved since the last pass.
    ///
    /// A diff rather than per-site emission: every verb, every guest-driven
    /// transition, and every reconcile with disk lands in the same model, so
    /// one reader of that model reports them all and no path can forget to.
    /// The cost is coalescing — a VM that passed through `.starting` between
    /// two passes reports only where it ended up. An arrival's adoption reads
    /// as a status change from ``VMStatus/preparingWireName``.
    private func emitLibraryChanges() {
        let current = currentObservedStates()
        var batch: [VMLibraryEvent] = []
        for entry in library.entries {
            let id = entry.id
            guard let now = current[id] else { continue }
            guard let before = lastObserved[id] else {
                batch.append(.added(summary(entry)))
                continue
            }
            if before.status != now.status {
                batch.append(
                    .statusChanged(
                        id: id, name: now.name, from: before.wireStatus, to: now.wireStatus))
                if now.status == .error {
                    batch.append(
                        .failure(
                            id: id, name: now.name,
                            message: now.errorMessage
                                ?? "The virtual machine stopped with an error."))
                }
            }
            if before.agentStatus != now.agentStatus {
                batch.append(
                    .agentStatusChanged(
                        id: id, name: now.name, status: now.agentStatus.wireName))
            }
            if before.name != now.name {
                batch.append(.renamed(id: id, from: before.name, to: now.name))
            }
        }
        for (id, before) in lastObserved where current[id] == nil {
            batch.append(.removed(id: id, name: before.name))
        }
        lastObserved = current
        broadcaster.emit(batch)
    }

    // MARK: - Failure Surfacing

    /// Hands a failure that no command call is waiting on to ``onFailure``.
    func report(_ failure: CommandError, on instance: VMInstance?) {
        onFailure?(failure, instance)
    }

    /// Reports work the app ran with nobody awaiting it, putting the failure on
    /// the event stream when the model it left behind cannot.
    ///
    /// ``emitLibraryChanges()`` reports a failure for a VM whose new status is
    /// the error status, reading the message off the phase. A transient failure
    /// rests the VM where the attempt began instead, carrying no message
    /// (``VirtualizationService/restingPhaseAfterStartFailure(_:transientRestingPhase:)``),
    /// so the diff has nothing to report and a subscriber would see only a
    /// status change back to where it started. One that does rest in the error
    /// status is left to the diff, so either way exactly one failure is
    /// reported. A refusal raised before the work ran gets none: nothing about
    /// the VM moved, and a caller waiting on a state is still owed its wait.
    func reportUnattendedFailure(_ failure: CommandError, on instance: VMInstance) {
        if failure.isOperationFailure, instance.status != .error {
            broadcaster.emit([
                .failure(id: instance.instanceID, name: instance.name, message: failure.message)
            ])
        }
        report(failure, on: instance)
    }

    /// The failure `arrival` settled with, or `nil` when it was cancelled —
    /// a cancel the user took is no failure to report, and the pipeline
    /// throws every outcome of one as `CancellationError`.
    func arrivalFailure(_ error: any Error, of arrival: VMArrival) -> CommandError? {
        guard !(error is CancellationError) else { return nil }
        return error as? CommandError
            ?? .operationFailed(verb: arrival.kind.verb, message: error.localizedDescription)
    }

    /// Puts an arrival's failure on the event stream, waited or not, while its
    /// row is still in the library: the diff in ``emitLibraryChanges()`` only
    /// ever sees the row vanish, and reports that after this.
    private func arrivalFailed(_ arrival: VMArrival, with error: any Error) {
        guard let failure = arrivalFailure(error, of: arrival) else { return }
        broadcaster.emit([.failure(id: arrival.id, name: arrival.name, message: failure.message)])
    }
}
