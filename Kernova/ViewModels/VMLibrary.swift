import Foundation
import os

/// The set of VMs the app knows about, and the bookkeeping that keeps it in
/// step with the bundles on disk: membership and sidebar ordering, the library
/// read, the directory-watched reconcile, `prepareBundle`/`registerPhantom`/
/// `evict`, the configuration persistence funnel, and the revert registry.
///
/// It also sequences two collaborators it owns — ``networkSlots`` and
/// ``removableMedia`` — because only the library knows where in a configuration
/// write each of them belongs.
///
/// Headless: it imports no AppKit and holds no presenter. Anything a user has
/// to be told about leaves through ``onFailure``, and the `VMInstance` hooks
/// whose handling belongs elsewhere — ``onAgentBecameCurrent``,
/// ``onPoweredOff`` and ``onEvicted`` — leave through their own closures.
/// ``VMLibraryViewModel`` is the AppKit adapter that owns one of these and
/// wires them all.
@MainActor
@Observable
final class VMLibrary: VMInstanceRoster {
    nonisolated private static let logger = Logger(subsystem: "app.kernova", category: "VMLibrary")

    // MARK: - Services

    private let storageService: any VMStorageProviding
    private let snapshotStore: any VMSnapshotStoring
    private let lifecycle: VMLifecycleCoordinator

    private let fileSystem: any FileSystemOperating

    private let preferences: AppPreferences

    // MARK: - Collaborators

    /// Drives a running VM's XHCI removable-media list to what its
    /// configuration asks for, dispatched from ``applyLivePolicy(for:old:new:)``.
    @ObservationIgnored let removableMedia: VMRemovableMediaReconciler

    /// The DHCP-reservation and port-forwarding slots each VM holds, and the
    /// MAC-address uniqueness both are keyed on.
    @ObservationIgnored let networkSlots: VMNetworkSlotRegistry

    // MARK: - Adapter Hooks

    /// Receives every failure the library needs a user to see.
    ///
    /// The library presents nothing itself; the adapter routes these to its
    /// presenter, buffering them until one is attached.
    @ObservationIgnored var onFailure: ((_ title: String, _ message: String) -> Void)?

    /// Fires when a VM's guest agent handshakes a current version, for the
    /// installer auto-eject.
    @ObservationIgnored var onAgentBecameCurrent: ((VMInstance) -> Void)?

    /// Fires when a VM powers off, for the Ephemeral Mode baseline revert.
    @ObservationIgnored var onPoweredOff: ((VMInstance) -> Void)?

    /// Fires when a VM leaves the library, so app-level state keyed on its id
    /// is released with it — whichever path evicted it.
    @ObservationIgnored var onEvicted: ((UUID) -> Void)?

    // MARK: - State

    var instances: [VMInstance] = []

    /// Whether the library's first read from disk has finished.
    ///
    /// `false` until then, so UI can tell "no VMs" from "not read yet" — an empty
    /// `instances` means nothing before the first `loadVMs()` applies. Stays
    /// `true` across later reloads, and is set even when the read fails: the
    /// answer is then known to be empty.
    private(set) var hasLoadedLibrary = false

    var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            preferences.lastSelectedVMID = selectedID
        }
    }

    /// `true` when any instance is mid-create, mid-clone, or mid-import.
    // RATIONALE: global and unbounded on purpose. `reconcileWithDisk` skips while
    // this is true, and `cancelPreparingConfirmed` keeps a cancelling row in
    // `instances` for the same reason: any gap lets reconcile resurrect a bundle
    // whose uninterruptible copy is still settling. A wedged `FileManager.copyItem`
    // therefore holds the gate until relaunch.
    var hasPreparing: Bool { instances.contains(where: \.isPreparing) }

    /// Whether any VM is doing work that terminating would destroy rather than
    /// suspend — a bundle still being created, cloned or imported, a VM
    /// mid-save/restore/start/install, or a revert writing a snapshot's files
    /// back over the bundle.
    ///
    /// Excludes settled `.running` and `.paused` VMs, which termination
    /// save-suspends.
    var hasUninterruptibleWork: Bool {
        instances.contains { $0.isPreparing || $0.isTransitioning }
            || hasRevertInFlight
    }

    /// Whether any VM is mid-save — the one operation an explicit quit has to
    /// wait out rather than terminate through.
    ///
    /// Narrower than ``hasUninterruptibleWork``, which the window reconcile uses
    /// to hold back a quit nobody asked for.
    var hasSaveInFlight: Bool {
        instances.contains { $0.phase.terminationMustWaitOut }
    }

    /// Whether `instance` has work in flight that its sidebar row renders as busy.
    ///
    /// The lifecycle term is the one a pause or resume shows up in: both hold a
    /// status that reads as resting — `.running` for a pause, `.paused` for a
    /// resume — for the whole VZ await, so ``VMStatus`` alone renders nothing
    /// while one is settling.
    func isBusy(_ instance: VMInstance) -> Bool {
        instance.isPreparing || instance.isTransitioning
            || lifecycle.hasUnsettledOperation(for: instance.id)
    }

    private var customOrder: [UUID] = []

    /// Bundle names whose load failures have already been reported to the user.
    ///
    /// Prevents repeated error dialogs for persistently corrupted bundles across
    /// successive `reconcileWithDisk()` calls.
    private var reportedFailedBundles: Set<String> = []

    // MARK: - Directory Watcher

    private var directoryWatcher: VMDirectoryWatcher?

    var selectedInstance: VMInstance? {
        instances.first { $0.id == selectedID }
    }

    // MARK: - Initialization

    init(
        storageService: any VMStorageProviding,
        snapshotStore: any VMSnapshotStoring,
        lifecycle: VMLifecycleCoordinator,
        fileSystem: any FileSystemOperating,
        preferences: AppPreferences,
        vmnetNetworks: any VmnetNetworkProviding,
        isVMNetworkingEntitled: Bool
    ) {
        self.storageService = storageService
        self.snapshotStore = snapshotStore
        self.lifecycle = lifecycle
        self.fileSystem = fileSystem
        self.preferences = preferences
        self.removableMedia = VMRemovableMediaReconciler(lifecycle: lifecycle)
        self.networkSlots = VMNetworkSlotRegistry(
            vmnetNetworks: vmnetNetworks, isVMNetworkingEntitled: isVMNetworkingEntitled)

        // Assigned after every stored property is set: each closure — and the
        // roster — references the library, which cannot be named before then.
        removableMedia.onSaveConfiguration = { [weak self] instance in
            self?.saveConfiguration(for: instance)
        }
        removableMedia.onFailure = { [weak self] error in
            self?.presentError(error)
        }
        networkSlots.roster = self
        networkSlots.onFailure = { [weak self] title, message in
            self?.surfaceError(message, title: title)
        }
    }

    /// Fills the library from disk, then starts watching the VMs directory for
    /// changes made outside the app.
    ///
    /// Called once, from `applicationWillFinishLaunching`. Deliberately not part
    /// of `init`: everything the initializer does runs before `NSApplication.run()`,
    /// so a library read there sits between process start and the first window.
    /// The watcher starts only after the read applies — its callback re-reads
    /// every bundle on the main actor, which must not race the initial load.
    func startLibrary() async {
        await loadVMs()
        startDirectoryWatcher()
    }

    // MARK: - Initial Phase

    /// Phase to assign to a VM when it's first loaded from disk or imported.
    ///
    /// A surviving install context — either guest's — is the canonical signal
    /// that the VM has never completed its initial boot, so it outranks
    /// `.suspended`/`.stopped`.
    nonisolated static func initialPhase(for config: VMConfiguration, layout: VMBundleLayout)
        -> VMLifecyclePhase
    {
        if config.hasPendingSetup {
            return .initialBoot
        }
        return layout.hasSaveFile ? .suspended : .stopped
    }

    // MARK: - Load

    /// One VM bundle as read from disk, before it becomes a `VMInstance`.
    ///
    /// `VMInstance` is `@MainActor`, so the read and the model construction have
    /// to be separable: this is what crosses back from the reading task.
    private struct ScannedBundle: Sendable {
        let configuration: VMConfiguration
        let bundleURL: URL
        let phase: VMLifecyclePhase
    }

    /// The whole library as read from disk in one pass.
    private struct LibraryScan: Sendable {
        var bundles: [ScannedBundle] = []
        /// Bundle names whose configuration could not be read.
        var failedBundleNames: [String] = []
    }

    /// Reads every bundle under the VMs directory.
    ///
    /// Nonisolated so the disk work can run off the main actor; it touches no
    /// library state and reports failures through the returned scan.
    private nonisolated static func scanLibrary(using storage: any VMStorageProviding) throws -> LibraryScan {
        var scan = LibraryScan()
        for bundleURL in try storage.listVMBundles() {
            do {
                let config = try storage.loadConfiguration(from: bundleURL)
                scan.bundles.append(
                    ScannedBundle(
                        configuration: config,
                        bundleURL: bundleURL,
                        phase: initialPhase(for: config, layout: VMBundleLayout(bundleURL: bundleURL))))
            } catch {
                logger.error(
                    "Failed to load VM from \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                scan.failedBundleNames.append(bundleURL.deletingPathExtension().lastPathComponent)
            }
        }
        return scan
    }

    /// Replaces the library with what is on disk.
    ///
    /// The read runs off the main actor — a library of any size is bound by
    /// per-bundle file reads, and blocking the main actor for them stalls
    /// whatever window is already on screen.
    func loadVMs() async {
        reportedFailedBundles.removeAll()
        let storage = storageService
        // The read is asynchronous, so the library can be mutated while it runs.
        // Anything appearing in `instances` after this line is newer than
        // whatever the read returns, and the result must not delete it.
        let knownBeforeRead = Set(instances.map(\.id))
        // Whatever the read returns, it is over: a listing that failed answers
        // "no VMs" too, and UI must not go on waiting for a load that finished.
        defer { hasLoadedLibrary = true }
        do {
            let scan = try await Task.detached(priority: .userInitiated) {
                try Self.scanLibrary(using: storage)
            }.value
            apply(scan, keepingInstancesAddedSince: knownBeforeRead)
        } catch {
            Self.logger.error("Failed to load VM library: \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    /// Turns a scan into the live library: instances, order, and selection.
    ///
    /// Instances registered since the read began outlive it, and outrank the
    /// read's view of the same VM. A preparing phantom is the case that matters:
    /// its copy is uninterruptible, so dropping the row would leave the copy
    /// running against a bundle the library has forgotten — with no row to
    /// cancel from, and `hasPreparing` back to `false`, which is exactly the gap
    /// `reconcileWithDisk` refuses to open.
    private func apply(_ scan: LibraryScan, keepingInstancesAddedSince knownBeforeRead: Set<UUID>) {
        let addedDuringRead = instances.filter { !knownBeforeRead.contains($0.id) }
        let addedDuringReadIDs = Set(addedDuringRead.map(\.id))
        instances =
            scan.bundles
            .filter { !addedDuringReadIDs.contains($0.configuration.id) }
            .map { scanned in
                let instance = VMInstance(
                    configuration: scanned.configuration, bundleURL: scanned.bundleURL,
                    phase: scanned.phase, preferences: preferences)
                wirePersistence(for: instance)
                return instance
            } + addedDuringRead
        networkSlots.logDuplicateMACAddressHolders()

        if !scan.failedBundleNames.isEmpty {
            reportedFailedBundles.formUnion(scan.failedBundleNames)
            presentError(LoadError.bundleLoadFailed(names: scan.failedBundleNames))
        }

        if let savedOrder = preferences.vmOrder {
            customOrder = savedOrder
            Self.logger.debug("Loaded custom VM order: \(self.customOrder.count, privacy: .public) UUID(s)")
        } else {
            Self.logger.debug("No custom VM order found — using default createdAt sort")
        }
        sortInstances()
        customOrder = instances.map(\.id)

        if selectedID == nil || !instances.contains(where: { $0.id == selectedID }) {
            if let savedID = preferences.lastSelectedVMID,
                instances.contains(where: { $0.id == savedID })
            {
                selectedID = savedID
                Self.logger.debug("Restored last-selected VM from UserDefaults: \(savedID.uuidString)")
            } else {
                selectedID = instances.first?.id
            }
        }
        networkSlots.pruneAddressReservations(scanWasComplete: scan.failedBundleNames.isEmpty)
        Self.logger.notice("Loaded \(self.instances.count, privacy: .public) VMs")
    }

    // MARK: - Revert Registry

    /// One revert in flight, and the VM whose bundle it rewrites.
    struct RevertRegistration {
        let instanceID: UUID
        let task: Task<Void, Never>
    }

    /// Every revert in flight, keyed by a per-request id.
    ///
    /// Keyed by the request rather than the VM: two reverts of one VM would
    /// share a slot and lose one of them, as would two ephemeral VMs powering
    /// off together under a VM-keyed map. Each registration names its VM, so a
    /// caller that only cares about one can still ask.
    ///
    /// The registry is library state — a revert rewrites the bundle a VM in
    /// `instances` is built from — while the verb that fills it belongs to the
    /// command core.
    var revertTasks: [UUID: RevertRegistration] = [:]

    /// Whether any revert is in flight — requested, whether or not it has
    /// reached the copy.
    var hasRevertInFlight: Bool { !revertTasks.isEmpty }

    /// Whether a revert of this VM in particular is in flight.
    ///
    /// The signal is set synchronously when the revert is requested, so a
    /// power-off's baseline revert is visible to anything that looks on the
    /// very next main-actor turn.
    func hasRevertInFlight(for instanceID: UUID) -> Bool {
        revertTasks.values.contains { $0.instanceID == instanceID }
    }

    /// Waits until no revert is in flight, including any a running revert
    /// starts.
    ///
    /// Unbounded, matching the termination pass's other waits: a revert
    /// interrupted mid-write is what the wait exists to prevent.
    ///
    /// A revert of a live VM resumes it once the files are in place, and the
    /// wait spans that resume rather than ending at the copy — so the VM the
    /// revert hands back live is save-suspended by the pass, which is what
    /// termination does with any live VM. Ending at the copy would need a
    /// second signal beside this registry and would leave the guest to die
    /// inside `restoreMachineStateFrom`.
    func waitForRevertsToSettle() async {
        while let registration = revertTasks.values.first { await registration.task.value }
    }

    // MARK: - Preparing Rows (shared by Create, Clone & Import)

    /// Adds a freshly-built phantom `VMInstance` to the library and selects it.
    ///
    /// Selection moves only when nothing else is preparing, so a second phantom
    /// registering mid-operation can't steal the sidebar's focus from the one the
    /// user is already watching.
    private func registerPhantom(_ phantom: VMInstance) {
        wirePersistence(for: phantom)
        instances.append(phantom)
        sortInstances()
        persistOrder()
        networkSlots.logDuplicateMACAddressHolders()
        if selectedInstance?.isPreparing != true {
            selectedID = phantom.id
        }
    }

    /// Registers `phantom`, runs `copyWork` off a spawned `Task`, and wires the cleanup create,
    /// clone and import all need around a preparing row's bundle write.
    ///
    /// `copyWork` is uninterruptible (a blocking `FileManager` call), so a user cancel cancels this
    /// outer `Task` while the copy keeps writing. This task is the single owner of the settle: on
    /// cancel it removes the "Cancelling…" row and trashes the bundle once the copy is done.
    ///
    /// `onSuccess` runs with the row already out of its preparing state, so a
    /// verb it chains — the start a create auto-starts with — is not refused by
    /// the preparing gate the row was still holding.
    func prepareBundle(
        _ phantom: VMInstance,
        operation: VMInstance.PreparingOperation,
        copyWork: @escaping () async throws -> Void,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        registerPhantom(phantom)
        let fileSystem = fileSystem
        let task = Task { [weak self] in
            defer { phantom.preparingState = nil }
            do {
                try await copyWork()
                guard let self else {
                    if Task.isCancelled {
                        Self.trashPartialBundle(at: phantom.bundleURL, fileSystem: fileSystem)
                    } else {
                        Self.logger.warning(
                            "\(operation.displayNoun, privacy: .public) completed but the library was deallocated — VM '\(phantom.name, privacy: .public)' exists on disk but was not added to library"
                        )
                    }
                    return
                }
                if Task.isCancelled {
                    // Cancelled mid-copy: `VMCommandCore.cancelPreparing` left the "Cancelling…" row
                    // in place, so remove it and trash the settled bundle now that the copy is done.
                    self.cleanupPhantomInstance(phantom)
                    return
                }
                phantom.preparingState = nil
                onSuccess()
            } catch {
                guard let self else {
                    Self.trashPartialBundle(at: phantom.bundleURL, fileSystem: fileSystem)
                    Self.logger.error(
                        "\(operation.displayNoun, privacy: .public) failed and the library was deallocated — trashed partial bundle '\(phantom.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                self.cleanupPhantomInstance(phantom)
                if !Task.isCancelled {
                    Self.logger.error(
                        "\(operation.displayNoun, privacy: .public) failed for VM '\(phantom.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                    )
                    onFailure(error)
                }
            }
        }
        phantom.preparingState = VMInstance.PreparingState(operation: operation, task: task)
    }

    /// A collision-free destination bundle URL under `vmsDir` for a bundle named like `sourceURL`.
    ///
    /// Taken names are the union of on-disk `.kernova` bundles in `vmsDir` AND the reserved names
    /// of already-registered phantoms there: a prior bundle's copy hasn't run yet, so a disk
    /// listing alone can't see it. Matched case-insensitively to mirror the default
    /// case-insensitive APFS volume.
    func reserveDestination(for sourceURL: URL, in vmsDir: URL) -> URL {
        let onDiskStems =
            (try? FileManager.default.contentsOfDirectory(
                at: vmsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .filter { VMStorageService.isBundleURL($0) }
            .map { $0.deletingPathExtension().lastPathComponent } ?? []
        let vmsDirPath = vmsDir.standardizedFileURL.path(percentEncoded: false)
        let inFlightStems = instances.compactMap { phantom -> String? in
            let url = phantom.bundleURL
            guard url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false) == vmsDirPath
            else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
        let name = UniqueName.firstAvailable(
            prefix: sourceURL.deletingPathExtension().lastPathComponent,
            existing: onDiskStems + inFlightStems,
            caseInsensitive: true)
        return vmsDir.appendingPathComponent(
            "\(name).\(VMStorageService.bundleExtension)", isDirectory: true)
    }

    /// Removes a phantom instance from the library, clears its preparing state, and trashes its partial bundle.
    func cleanupPhantomInstance(_ phantom: VMInstance) {
        evict(phantom)
        persistOrder()
        phantom.preparingState = nil
        Self.trashPartialBundle(at: phantom.bundleURL, fileSystem: fileSystem)
    }

    /// Drops `instance` from the library, moving the selection off it and
    /// releasing the app-level state keyed on it.
    ///
    /// `bundleIsGone: false` drops the row but keeps the VM's DHCP reservation
    /// slot, for a bundle still on disk whose configuration could not be read —
    /// that VM still exists, so handing its address to somebody else would move
    /// it once the configuration is readable again.
    func evict(_ instance: VMInstance, bundleIsGone: Bool = true) {
        instances.removeAll { $0.id == instance.id }
        if selectedID == instance.id {
            selectedID = instances.first?.id
        }
        // A VM out of the library stops claiming its host ports and its
        // address, so the next VM created can be handed both.
        networkSlots.releaseSlots(for: instance.configuration, bundleIsGone: bundleIsGone)
        networkSlots.rebuildNetworksIfIdle()
        onEvicted?(instance.id)
    }

    // MARK: - Reorder

    /// Moves VMs in the sidebar list and persists the new order.
    func moveVM(fromOffsets source: IndexSet, toOffset destination: Int) {
        instances.move(fromOffsets: source, toOffset: destination)
        persistOrder()
        Self.logger.notice("Reordered VMs in sidebar")
    }

    /// Sorts instances by custom order, falling back to `createdAt` for unordered VMs.
    private func sortInstances() {
        let orderMap = Dictionary(zip(customOrder, customOrder.indices), uniquingKeysWith: { first, _ in first })
        instances.sort { lhs, rhs in
            switch (orderMap[lhs.id], orderMap[rhs.id]) {
            case let (.some(l), .some(r)):
                return l < r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.configuration.createdAt < rhs.configuration.createdAt
            }
        }
    }

    /// Snapshots the current instance order into customOrder and persists it via `AppPreferences.vmOrder`.
    func persistOrder() {
        customOrder = instances.map(\.id)
        preferences.vmOrder = customOrder
    }

    // MARK: - Save Configuration

    /// Writes `instance.configuration` to its bundle, reporting whether it landed.
    ///
    /// A failure is logged and presented; the in-memory value stands.
    @discardableResult
    func saveConfiguration(for instance: VMInstance) -> Bool {
        do {
            try storageService.saveConfiguration(instance.configuration, to: instance.bundleURL)
            return true
        } catch {
            Self.logger.error(
                "Failed to save configuration for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
            return false
        }
    }

    /// Routes guest-driven mutations through the centralized `updateConfiguration`
    /// dispatcher.
    ///
    /// Called at every `VMInstance` construction site the library and its adapter own.
    func wirePersistence(for instance: VMInstance) {
        // Both closures are stored *on* `instance`, so they must capture it weakly:
        // a strong capture forms a self-retain cycle that leaks the VMInstance after
        // it's removed from `instances`.
        instance.onUpdateConfiguration = { [weak self, weak instance] mutate in
            guard let self, let instance else { return }
            self.updateConfiguration(of: instance, mutate: mutate)
        }
        // Auto-eject the installer disk once the agent handshakes a current version.
        // Wired here so it fires regardless of which window is open.
        instance.onAgentBecameCurrent = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.onAgentBecameCurrent?(instance)
        }
        // Reservations and forwarding rules are fixed at network creation, so a
        // change made while a VM ran waits for the last session on that network
        // to release it.
        instance.onSessionTornDown = { [weak self, weak instance] in
            self?.networkSlots.rebuildNetworksIfIdle(ignoring: instance)
        }
        // An Ephemeral Mode VM goes back to its baseline on every power-off.
        instance.onPoweredOff = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.onPoweredOff?(instance)
        }
        // The one construction-site hook every path runs through — load, create,
        // clone, import, and disk reconciliation alike.
        instance.snapshotManifest = snapshotStore.loadManifest(bundleURL: instance.bundleURL)
        // Every one of those paths hands the library a bundle it does not hold
        // an instance for yet, and a revert needs one — so a staging directory
        // found here belongs to no running revert, and reclaiming it does not
        // wait on the next revert of this VM to come along.
        snapshotStore.sweepRestoreStaging(bundleURL: instance.bundleURL)
        networkSlots.claimSlots(for: instance.configuration)
        // The create/clone/import/load entry point: a VM arriving with a slot
        // on an already-materialized network is pending until it is recreated.
        networkSlots.rebuildNetworksIfIdle()
    }

    /// The single entry point for any UI-driven or programmatic mutation of
    /// `instance.configuration`.
    ///
    /// Applies the mutation, persists the result, and dispatches the live policy /
    /// removable-media reconcile. No-ops when the mutation produces the same value.
    ///
    /// A mutation moving the VM onto a MAC address another VM holds is refused
    /// whole — no field it also sets is applied — so this is the one place every
    /// writer of an address passes through.
    ///
    /// - Returns: Whether the new configuration reached disk. A no-op mutation
    ///   returns `true`; a failed write leaves the new value in memory, so a
    ///   caller that needs memory and disk to agree rolls back on `false`. A
    ///   refused mutation also returns `false`, having left the configuration
    ///   untouched.
    @discardableResult
    func updateConfiguration(
        of instance: VMInstance,
        mutate: (inout VMConfiguration) -> Void
    ) -> Bool {
        let old = instance.configuration
        var new = old
        mutate(&new)
        guard new != old else { return true }
        guard !networkSlots.refuseSlotConflict(on: instance, movingFrom: old, to: new) else {
            return false
        }
        instance.configuration = new
        networkSlots.moveSlots(from: old, to: new)
        let saved = saveConfiguration(for: instance)
        // A live session still reads as attached to the network it is *on*, so
        // the network this VM is switching *to* is idle only until
        // `applyLivePolicy` attaches it — which it does synchronously. Recreate
        // it now, or the change this VM just declared waits for a teardown.
        networkSlots.rebuildNetworksIfIdle()
        applyLivePolicy(for: instance, old: old, new: new)
        // A live switch off a network frees it inside `applyLivePolicy` — the
        // pass above ran while the session still held that attachment, so
        // re-check now rather than leaving the pending change to an unrelated
        // event.
        networkSlots.rebuildNetworksIfIdle()
        return saved
    }

    /// Pushes a configuration change to a running VM.
    ///
    /// Hot-toggleable fields (`agentLogForwardingEnabled`, `clipboardSharingEnabled`)
    /// take effect immediately via `VMInstance.applyLivePolicy`; changes to
    /// `removableMedia` trigger a runtime XHCI list-diff; everything else is
    /// persisted-only and waits for next start.
    func applyLivePolicy(for instance: VMInstance, old: VMConfiguration, new: VMConfiguration) {
        instance.applyLivePolicy(oldConfig: old, newConfig: new)
        removableMedia.apply(for: instance, old: old, new: new)
    }

    // MARK: - Directory Watcher

    private func startDirectoryWatcher() {
        let vmsDir: URL
        do {
            vmsDir = try storageService.vmsDirectory
        } catch {
            Self.logger.warning(
                "Could not resolve VMs directory for file system watcher: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        let watcher = VMDirectoryWatcher { [weak self] in
            self?.reconcileWithDisk()
        }
        watcher.start(directory: vmsDir)
        directoryWatcher = watcher
    }

    /// Diffs on-disk VM bundles against in-memory instances and adds/removes as needed.
    func reconcileWithDisk() {
        guard !hasPreparing else {
            Self.logger.debug("reconcileWithDisk: skipped — preparing operation in progress")
            return
        }
        Self.logger.debug("reconcileWithDisk: starting")
        do {
            let diskBundles = try storageService.listVMBundles()

            var diskConfigs: [(VMConfiguration, URL)] = []
            var failedBundles: [String] = []
            // Bundles present on disk but unreadable: their VMs still exist, so
            // eviction must not reclaim what is keyed on them.
            var failedBundleURLs: Set<URL> = []
            for bundleURL in diskBundles {
                let bundleName = bundleURL.deletingPathExtension().lastPathComponent
                do {
                    let config = try storageService.loadConfiguration(from: bundleURL)
                    diskConfigs.append((config, bundleURL))
                    reportedFailedBundles.remove(bundleName)
                } catch {
                    Self.logger.error(
                        "Failed to load config from \(bundleURL.lastPathComponent, privacy: .public) during reconciliation: \(error.localizedDescription, privacy: .public)"
                    )
                    failedBundles.append(bundleName)
                    failedBundleURLs.insert(bundleURL)
                }
            }
            let diskIDs = Set(diskConfigs.map(\.0.id))
            let memoryIDs = Set(instances.map(\.id))

            var didChange = false
            for (config, bundleURL) in diskConfigs where !memoryIDs.contains(config.id) {
                let layout = VMBundleLayout(bundleURL: bundleURL)
                let instance = VMInstance(
                    configuration: config,
                    bundleURL: bundleURL,
                    phase: Self.initialPhase(for: config, layout: layout),
                    preferences: preferences
                )
                wirePersistence(for: instance)
                instances.append(instance)
                Self.logger.info("Discovered VM '\(config.name, privacy: .public)' on disk — added to library")
                didChange = true
            }

            // Only remove resting-state VMs — never touch running/paused/preparing ones.
            let instancesToRemove = instances.filter { instance in
                !diskIDs.contains(instance.id)
                    && !instance.isPreparing
                    && (instance.status == .stopped
                        || instance.status == .error
                        || instance.status == .initialBoot)
            }
            for instance in instancesToRemove {
                // Cancel any in-flight setup task before evicting — otherwise it keeps
                // mutating an orphan instance the library no longer knows about.
                instance.setupTask?.cancel()
                evict(instance, bundleIsGone: !failedBundleURLs.contains(instance.bundleURL))
                Self.logger.info("VM '\(instance.name, privacy: .public)' no longer on disk — removed from library")
                didChange = true
            }

            if didChange {
                sortInstances()
                persistOrder()
                networkSlots.logDuplicateMACAddressHolders()
            }

            let newFailures = failedBundles.filter { !reportedFailedBundles.contains($0) }
            let suppressedCount = failedBundles.count - newFailures.count
            if suppressedCount > 0 {
                Self.logger.debug(
                    "reconcileWithDisk: suppressed \(suppressedCount, privacy: .public) already-reported bundle failure(s)"
                )
            }
            if !newFailures.isEmpty {
                reportedFailedBundles.formUnion(newFailures)
                presentError(LoadError.bundleLoadFailed(names: newFailures))
            }

            // Prune names of bundles no longer on disk so a new bundle with the same name
            // is not silently suppressed.
            let currentDiskNames = Set(diskBundles.map { $0.deletingPathExtension().lastPathComponent })
            reportedFailedBundles.formIntersection(currentDiskNames)

            Self.logger.debug(
                "reconcileWithDisk: complete — \(self.instances.count, privacy: .public) VM(s) in library")
        } catch {
            Self.logger.error("Directory reconciliation failed: \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    // MARK: - Error Handling

    /// Moves a partial VM bundle to the Trash in the background, logging on failure.
    ///
    /// Static (with the file-system seam passed in) because it must stay callable after
    /// `guard let self else` — the cleanup must not depend on the library.
    static func trashPartialBundle(at url: URL, fileSystem: any FileSystemOperating) {
        let log = logger
        Task.detached {
            do {
                try fileSystem.trashItem(at: url)
            } catch {
                log.error(
                    "Failed to clean up partial bundle at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Error type for VM loading failures.
    private enum LoadError: LocalizedError {
        case bundleLoadFailed(names: [String])

        var errorDescription: String? {
            switch self {
            case .bundleLoadFailed(let names):
                assert(!names.isEmpty, "bundleLoadFailed requires at least one bundle name")
                return
                    "Failed to load the following VMs: \(names.joined(separator: ", ")). They may have corrupted configurations."
            }
        }
    }

    private func presentError(_ error: Error) {
        surfaceError(error.localizedDescription)
    }

    /// Hands an error message to ``onFailure``.
    private func surfaceError(_ message: String, title: String = "Error") {
        onFailure?(title, message)
    }
}
