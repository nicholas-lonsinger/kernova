import Foundation
import os

/// The set of VMs the app knows about, and the bookkeeping that keeps it in
/// step with the bundles on disk: the library read, the directory watcher, the
/// sleep/wake pass, configuration persistence, DHCP-reservation and
/// port-forwarding slots, and sidebar ordering.
///
/// Headless: it imports no AppKit and holds no presenter. Anything a user has
/// to be told about leaves through ``onFailure``, and the two `VMInstance`
/// hooks whose handling belongs to a verb — ``onAgentBecameCurrent`` and
/// ``onPoweredOff`` — leave through their own closures. ``VMLibraryViewModel``
/// is the AppKit adapter that owns one of these and wires all three.
@MainActor
@Observable
final class VMLibrary {
    nonisolated private static let logger = Logger(subsystem: "app.kernova", category: "VMLibrary")

    // MARK: - Services

    private let storageService: any VMStorageProviding
    private let snapshotStore: any VMSnapshotStoring
    private let lifecycle: VMLifecycleCoordinator

    private let vmnetNetworks: any VmnetNetworkProviding

    /// Whether this build's reservation machinery is live — a process-wide
    /// constant, snapshotted at init.
    private let isVMNetworkingEntitled: Bool

    private let fileSystem: any FileSystemOperating

    private let preferences: AppPreferences

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

    /// VMs with an in-flight removable-media reconciliation Task.
    ///
    /// With `pendingRemovableMediaTarget`, coalesces rapid edits into one Task per
    /// instance: the `await`s inside `applyLiveRemovableMediaChange` leave the actor
    /// reentrant, so a second Task would read the same tracking and issue duplicate
    /// detach/attach operations.
    private var reconcilingRemovableMediaInstances: Set<UUID> = []

    /// Latest desired removable media list per instance, drained by
    /// `runRemovableMediaReconciliation` until empty.
    private var pendingRemovableMediaTarget: [UUID: [RemovableMediaItem]] = [:]

    /// `true` when any instance is mid-clone or mid-import.
    // RATIONALE: global and unbounded on purpose. `reconcileWithDisk` skips while
    // this is true, and `cancelPreparingConfirmed` keeps a cancelling row in
    // `instances` for the same reason: any gap lets reconcile resurrect a bundle
    // whose uninterruptible copy is still settling. A wedged `FileManager.copyItem`
    // therefore holds the gate until relaunch.
    var hasPreparing: Bool { instances.contains(where: \.isPreparing) }

    /// Whether any VM is doing work that terminating would destroy rather than
    /// suspend — an import mid-copy, a VM mid-save/restore/start/install, or a
    /// revert writing a snapshot's files back over the bundle.
    ///
    /// Excludes settled `.running` and `.paused` VMs, which termination
    /// save-suspends.
    var hasUninterruptibleWork: Bool {
        instances.contains { $0.isPreparing || $0.status.isTransitioning }
            || hasRevertInFlight
    }

    /// Whether any VM is mid-save — the one operation an explicit quit has to
    /// wait out rather than terminate through.
    ///
    /// Narrower than ``hasUninterruptibleWork``, which the window reconcile uses
    /// to hold back a quit nobody asked for.
    var hasSaveInFlight: Bool {
        instances.contains { $0.status.terminationMustWaitOut }
    }

    /// Whether `instance` has work in flight that its sidebar row renders as busy.
    ///
    /// The lifecycle term is the one a pause or resume shows up in: both hold a
    /// status that reads as resting — `.running` for a pause, `.paused` for a
    /// resume — for the whole VZ await, so ``VMStatus`` alone renders nothing
    /// while one is settling.
    func isBusy(_ instance: VMInstance) -> Bool {
        instance.isPreparing || instance.status.isTransitioning
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

    // MARK: - Sleep/Wake

    private var sleepWatcher: SystemSleepWatcher?
    var sleepPausedInstanceIDs: Set<UUID> = []

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
        self.vmnetNetworks = vmnetNetworks
        self.isVMNetworkingEntitled = isVMNetworkingEntitled

        startSleepWatcher()
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

    // MARK: - Initial Status

    /// Status to assign to a VM when it's first loaded from disk or imported.
    ///
    /// A surviving install context — either guest's — is the canonical signal
    /// that the VM has never completed its initial boot, so it outranks
    /// `.paused`/`.stopped`.
    nonisolated static func initialStatus(for config: VMConfiguration, layout: VMBundleLayout) -> VMStatus {
        if config.hasPendingSetup {
            return .initialBoot
        }
        return layout.hasSaveFile ? .paused : .stopped
    }

    // MARK: - Load

    /// One VM bundle as read from disk, before it becomes a `VMInstance`.
    ///
    /// `VMInstance` is `@MainActor`, so the read and the model construction have
    /// to be separable: this is what crosses back from the reading task.
    private struct ScannedBundle: Sendable {
        let configuration: VMConfiguration
        let bundleURL: URL
        let status: VMStatus
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
                        status: initialStatus(for: config, layout: VMBundleLayout(bundleURL: bundleURL))))
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
                    status: scanned.status, preferences: preferences)
                wirePersistence(for: instance)
                return instance
            } + addedDuringRead
        logDuplicateMACAddressHolders()

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
        pruneAddressReservations(scanWasComplete: scan.failedBundleNames.isEmpty)
        Self.logger.notice("Loaded \(self.instances.count, privacy: .public) VMs")
    }

    /// Frees every reservation slot no VM in the library claims — the reclaim
    /// for slots orphaned while the app was not running (a bundle trashed in
    /// Finder), which no in-session release can catch.
    ///
    /// Runs only over a complete library: a bundle whose configuration failed
    /// to parse is absent from `instances` while its VM still exists, so its
    /// slot must not be handed to somebody else. Entitlement-gated like the
    /// rest of the reservation machinery — an unentitled build never reserves,
    /// so pruning there would empty a store the entitled build owns.
    private func pruneAddressReservations(scanWasComplete: Bool) {
        guard isVMNetworkingEntitled, scanWasComplete else { return }
        let targets = instances.compactMap { reservationTarget(for: $0.configuration) }
        for kind in VmnetNetworkKind.allCases {
            let macs = Set(targets.filter { $0.kind == kind }.map(\.mac))
            vmnetNetworks.retainAddressReservations(macs, kind: kind)
        }
        // A reload can run while a network is materialized, so the slots this
        // just reclaimed only reach guests through a recreate.
        rebuildNetworksIfIdle()
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

    // MARK: - Preparing Rows (shared by Clone & Import)

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
        logDuplicateMACAddressHolders()
        if selectedInstance?.isPreparing != true {
            selectedID = phantom.id
        }
    }

    /// Registers `phantom`, runs `copyWork` off a spawned `Task`, and wires the cleanup both clone
    /// and import need around a preparing row's file copy.
    ///
    /// `copyWork` is uninterruptible (a blocking `FileManager` call), so a user cancel cancels this
    /// outer `Task` while the copy keeps writing. This task is the single owner of the settle: on
    /// cancel it removes the "Cancelling…" row and trashes the bundle once the copy is done.
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
                        "Failed to \(operation.displayNoun.lowercased(), privacy: .public) VM '\(phantom.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
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
        withdrawPortForwardingRules(for: instance.configuration)
        if bundleIsGone, let target = reservationTarget(for: instance.configuration) {
            releaseAddressReservationIfUnused(target)
        }
        rebuildNetworksIfIdle()
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
            self?.rebuildNetworksIfIdle(ignoring: instance)
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
        syncAddressReservation(for: instance.configuration)
        syncPortForwardingRules(for: instance.configuration)
        // The create/clone/import/load entry point: a VM arriving with a slot
        // on an already-materialized network is pending until it is recreated.
        rebuildNetworksIfIdle()
    }

    /// The reservation slot `config` wants: the network its mode maps to and
    /// the lowercased MAC keying the slot, `nil` for a VM that can join no
    /// app-managed network (networking off, or Bridged, where external DHCP
    /// owns addressing).
    private func reservationTarget(
        for config: VMConfiguration
    ) -> (kind: VmnetNetworkKind, mac: String)? {
        guard config.networkEnabled, let mac = config.macAddress,
            let kind = VmnetNetworkKind(mode: config.networkMode)
        else { return nil }
        return (kind: kind, mac: mac.lowercased())
    }

    /// Keeps the VM's DHCP reservation slot in step with its configuration:
    /// any VM that can join an app-managed network holds a slot keyed on its
    /// persisted MAC, so its address is assigned before the network next
    /// materializes. Runs at every instance construction and configuration
    /// change; cheap and idempotent. Entitlement-gated like every other
    /// consumer of the reservation machinery — an unentitled build never
    /// materializes a network, so slots taken there would be dead weight.
    private func syncAddressReservation(for config: VMConfiguration) {
        guard isVMNetworkingEntitled, let target = reservationTarget(for: config) else { return }
        vmnetNetworks.reserveAddressIfNeeded(for: target.mac, kind: target.kind)
    }

    /// Frees `target`'s reservation slot unless a VM still in the library wants
    /// the same one — a bundle can arrive carrying an address another VM already
    /// holds, so the last claimant is what releases the slot.
    private func releaseAddressReservationIfUnused(_ target: (kind: VmnetNetworkKind, mac: String)) {
        guard isVMNetworkingEntitled else { return }
        let stillWanted = instances.contains {
            let other = reservationTarget(for: $0.configuration)
            return other?.kind == target.kind && other?.mac == target.mac
        }
        guard !stillWanted else { return }
        vmnetNetworks.releaseAddressReservation(for: target.mac, kind: target.kind)
    }

    /// The address this VM's MAC reserves on the app-managed network it joins,
    /// or `nil` when it has none to report — networking off, Bridged (where
    /// external DHCP owns addressing), a build without the reservation
    /// machinery, or a slot whose network has not been materialized yet.
    ///
    /// Reads the reservation store without taking a slot: the sync at every
    /// configuration change is what claims one.
    func reservedAddress(for config: VMConfiguration) -> String? {
        guard isVMNetworkingEntitled, let target = reservationTarget(for: config) else { return nil }
        return vmnetNetworks.reservedAddress(for: target.mac, kind: target.kind)
    }

    /// Keeps the VM's port-forwarding rules in step with its configuration: a
    /// Shared Network VM declares its rules on that network, a VM in any other
    /// mode declares none. Runs wherever ``syncAddressReservation(for:)`` does.
    private func syncPortForwardingRules(for config: VMConfiguration) {
        let forwards = config.networkEnabled && config.networkMode == .shared
        declarePortForwardingRules(forwards ? config.portForwardingRules : [], for: config)
    }

    /// Declares `rules` for the VM `config` identifies.
    ///
    /// Entitlement-gated like the reservation machinery it rides on — an
    /// unentitled build attaches system NAT, which forwards nothing.
    private func declarePortForwardingRules(
        _ rules: [PortForwardingRule], for config: VMConfiguration
    ) {
        guard isVMNetworkingEntitled, let mac = config.macAddress else { return }
        vmnetNetworks.setPortForwardingRules(rules, for: mac, kind: .shared)
    }

    /// Withdraws the rules `config` declared, unless a VM still in the library
    /// carries the same MAC — rules are keyed on the address, so a blanket
    /// withdrawal would disarm that VM's rules too; its own are re-declared
    /// instead. An address is one VM's alone once it passes
    /// ``refuseIfDuplicateMACAddress(_:on:)``, so the survivor is a bundle that
    /// arrived carrying one already in use.
    private func withdrawPortForwardingRules(for config: VMConfiguration) {
        guard let mac = config.macAddress?.lowercased() else { return }
        let survivor = instances.first { $0.configuration.macAddress?.lowercased() == mac }
        if let survivor {
            syncPortForwardingRules(for: survivor.configuration)
        } else {
            declarePortForwardingRules([], for: config)
        }
    }

    /// The VMs other than `instance` whose configuration carries `mac`, in
    /// library order — the one lookup every duplicate-address question derives
    /// from.
    ///
    /// Case-insensitive, matching the reservation slots and forwarding rules the
    /// address keys. A VM with networking off counts: the address persists
    /// across mode changes, so turning networking back on would re-form the
    /// collision.
    private func vmsHoldingMACAddress(_ mac: String, otherThan instance: VMInstance) -> [VMInstance] {
        let wanted = mac.lowercased()
        return instances.filter {
            $0 !== instance && $0.configuration.macAddress?.lowercased() == wanted
        }
    }

    /// Names of the other VMs in the library carrying `instance`'s MAC address,
    /// in library order — empty when the address is this VM's alone.
    func vmNamesSharingMACAddress(with instance: VMInstance) -> [String] {
        guard let mac = instance.configuration.macAddress else { return [] }
        return vmsHoldingMACAddress(mac, otherThan: instance).map(\.name)
    }

    /// Records every MAC address two or more VMs in the library hold.
    ///
    /// Import, load and reconcile admit whatever address a bundle arrives
    /// carrying, so this is where a pair the app never authored becomes
    /// traceable. Runs on each of those three, which are the paths a VM the app
    /// did not author an address for enters by.
    private func logDuplicateMACAddressHolders() {
        let holders = Dictionary(grouping: instances) { $0.configuration.macAddress?.lowercased() }
        for (mac, vms) in holders where mac != nil && vms.count > 1 {
            let names = vms.map { "'\($0.name)'" }.joined(separator: ", ")
            Self.logger.warning(
                "MAC address \(mac ?? "", privacy: .public) is held by \(names, privacy: .public)")
        }
    }

    /// Refuses a change that would give `instance` a MAC address another VM in
    /// the library holds, logging the refusal and surfacing the alert.
    ///
    /// - Returns: `true` when the caller must abort.
    private func refuseIfDuplicateMACAddress(_ mac: String, on instance: VMInstance) -> Bool {
        guard let holder = vmsHoldingMACAddress(mac, otherThan: instance).first else { return false }
        Self.logger.notice(
            "Refused the MAC address \(mac, privacy: .public) for '\(instance.name, privacy: .public)': '\(holder.name, privacy: .public)' already holds it"
        )
        surfaceError(
            "“\(holder.name)” already uses \(mac). "
                + "Each virtual machine needs its own MAC address. "
                + "Change or delete “\(holder.name)” first to move this address to “\(instance.name)”.",
            title: "MAC Address In Use")
        return true
    }

    /// Refuses an operation that would put a second guest on one MAC address on
    /// one network, logging the refusal and surfacing the alert.
    ///
    /// `config` is the configuration the VM would run under — its own at start,
    /// the prospective one for a live mode switch, which moves an unchanged
    /// address onto a different network.
    ///
    /// ``refuseIfDuplicateMACAddress(_:on:)`` keeps the library unique for every
    /// address the app writes; this covers the pair a bundle arrived carrying,
    /// which passed through no writer.
    ///
    /// - Returns: `true` when the caller must abort.
    func refuseIfDuplicateMACAddressConflict(
        _ instance: VMInstance, joining config: VMConfiguration
    ) -> Bool {
        guard let conflict = liveMACAddressConflict(for: config, excluding: instance),
            let mac = config.macAddress
        else { return false }
        Self.logger.notice(
            "Refused to run '\(instance.name, privacy: .public)': shares the MAC address \(mac, privacy: .public) with active VM '\(conflict.name, privacy: .public)'"
        )
        surfaceError(
            "“\(instance.name)” has the same MAC address as “\(conflict.name)”, which is active. "
                + "Two virtual machines with the same MAC address must not run on the same network at once. "
                + "Stop “\(conflict.name)” first, or give one of them a new address in Network settings.",
            title: "Duplicate MAC Address")
        return true
    }

    /// The first live VM sharing `config`'s MAC address on the network `config`
    /// joins, if any.
    ///
    /// Live means VZ holds the attachment, as it does for the machine identity.
    /// The mode names the network, so two holders collide only where both
    /// guests attach: networking off puts no address on a wire, and Shared,
    /// Host Only and Bridged are separate networks. Two bridged VMs compare as
    /// one network whatever interface each names — Automatic resolves at start,
    /// so which link they land on is not knowable in advance.
    func liveMACAddressConflict(
        for config: VMConfiguration, excluding instance: VMInstance
    ) -> VMInstance? {
        guard config.networkEnabled, let mac = config.macAddress else { return nil }
        return vmsHoldingMACAddress(mac, otherThan: instance).first { other in
            (other.status.isActive || other.isLivePaused)
                && other.configuration.networkEnabled
                && other.configuration.networkMode == config.networkMode
        }
    }

    /// Recreates every app-managed network whose DHCP reservations or
    /// forwarding rules are no longer the ones that should install, once no VM
    /// could be attached to it.
    ///
    /// Both are fixed at creation, so a change reaches guests only through a
    /// recreate — and only while no session holds an attachment on the network.
    /// The recreate keeps the network's addressing, so no guest's address
    /// moves.
    /// `tornDown` is the instance whose session just ended, excluded from the
    /// idle scan: `tearDownSession` fires its hook before the caller settles
    /// the status, so a VM released from a transitioning one (`.saving` on a
    /// save-suspend, `.installing` on a cancelled guest setup) would otherwise
    /// read as still holding the network it just let go of.
    private func rebuildNetworksIfIdle(ignoring tornDown: VMInstance? = nil) {
        for kind in VmnetNetworkKind.allCases { rebuildNetworkIfIdle(kind, ignoring: tornDown) }
    }

    private func rebuildNetworkIfIdle(_ kind: VmnetNetworkKind, ignoring tornDown: VMInstance?) {
        guard vmnetNetworks.networkConfigurationIsPending(for: kind) else { return }
        let attached = instances.contains {
            $0 !== tornDown && $0.mayHoldAttachment(on: kind)
        }
        guard !attached else { return }
        Self.logger.notice(
            "Recreating the \(kind.rawValue, privacy: .public) network to install its pending changes"
        )
        vmnetNetworks.invalidateNetwork(for: kind)
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
        if let mac = new.macAddress, mac.lowercased() != old.macAddress?.lowercased(),
            refuseIfDuplicateMACAddress(mac, on: instance)
        {
            return false
        }
        // A live VM's Mode picker stays enabled, and a mode change hot-swaps the
        // attachment: the address is unchanged, so the refusal above never sees
        // it, and the network it lands on is not the one `start` checked. Only a
        // VM already running can form the collision this way, and only a
        // configuration not already in one is refused — a VM that reached a
        // collision by some other route has to stay editable to leave it.
        if instance.status.isActive || instance.isLivePaused,
            liveMACAddressConflict(for: old, excluding: instance) == nil,
            refuseIfDuplicateMACAddressConflict(instance, joining: new)
        {
            return false
        }
        instance.configuration = new
        // An edited MAC leaves its predecessor holding an older — so
        // higher-priority — reservation slot. Left declared there, the retired
        // address keeps claiming the VM's host ports and the rules re-declared
        // under the new one are dropped as duplicates.
        if let retired = old.macAddress, retired != new.macAddress {
            withdrawPortForwardingRules(for: old)
        }
        // Released before the new slot is taken, so the freed slot is the
        // lowest one available and an edited MAC normally keeps the VM's
        // address. Covers a MAC change, a mode switch, and networking off.
        if let retired = reservationTarget(for: old) {
            let kept = reservationTarget(for: new)
            if kept?.kind != retired.kind || kept?.mac != retired.mac {
                releaseAddressReservationIfUnused(retired)
            }
        }
        syncAddressReservation(for: new)
        syncPortForwardingRules(for: new)
        let saved = saveConfiguration(for: instance)
        // A live session still reads as attached to the network it is *on*, so
        // the network this VM is switching *to* is idle only until
        // `applyLivePolicy` attaches it — which it does synchronously. Recreate
        // it now, or the change this VM just declared waits for a teardown.
        rebuildNetworksIfIdle()
        applyLivePolicy(for: instance, old: old, new: new)
        // A live switch off a network frees it inside `applyLivePolicy` — the
        // pass above ran while the session still held that attachment, so
        // re-check now rather than leaving the pending change to an unrelated
        // event.
        rebuildNetworksIfIdle()
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

        let mediaChanged = VMConfiguration.removableMediaChanged(old: old, new: new)
        // Only dispatch when running/paused — stopped VMs persist the new media list
        // and pick it up on next start.
        guard mediaChanged, instance.status == .running || instance.status == .paused else { return }

        let id = instance.instanceID
        pendingRemovableMediaTarget[id] = new.removableMedia ?? []
        guard !reconcilingRemovableMediaInstances.contains(id) else { return }
        reconcilingRemovableMediaInstances.insert(id)
        Task { [weak self] in
            await self?.runRemovableMediaReconciliation(for: instance, id: id)
        }
    }

    /// Drains `pendingRemovableMediaTarget` for a single instance until empty.
    ///
    /// Writes that arrive during a pass are picked up by the next iteration, so rapid
    /// edits always converge to the final user-selected state.
    private func runRemovableMediaReconciliation(for instance: VMInstance, id: UUID) async {
        defer { reconcilingRemovableMediaInstances.remove(id) }
        while let target = pendingRemovableMediaTarget.removeValue(forKey: id) {
            // A VM that stopped mid-pass picks up the latest config on next start;
            // hitting XHCI on a torn-down VM would surface a spurious
            // `noVirtualMachine` error to the user.
            guard instance.status == .running || instance.status == .paused else { break }
            await applyLiveRemovableMediaChange(for: instance, target: target)
        }
    }

    /// Reconciles the live removable media list with `target`, diffing per id against
    /// `instance.liveRemovableMedia`.
    ///
    /// Detaches run before attaches, so swapping the medium in a slot cannot collide
    /// with itself on a duplicate UUID.
    ///
    /// On unexpected detach or attach errors the persisted config is rolled back to
    /// match `instance.liveRemovableMedia`, so the UI snaps to what is actually
    /// attached rather than describing a state VZ refused. `deviceNotFound` (which
    /// also covers a guest-side eject) and `noVirtualMachine` are handled as
    /// confirmed-gone / silent bail.
    private func applyLiveRemovableMediaChange(
        for instance: VMInstance,
        target: [RemovableMediaItem]
    ) async {
        let tracked = instance.liveRemovableMedia
        // Tolerate duplicate ids: a hand-edited or corrupted config.json could ship
        // two `removableMedia` entries with the same UUID, and a uniquing-free
        // Dictionary init would trap and take the host app down.
        let targetByID = Dictionary(target.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let trackedByID = Dictionary(tracked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Rollback lookup: tracked entries win over target entries on id collisions,
        // so a row that failed mid-swap restores its original path/readOnly. A
        // rebuilt entry keeps its persisted bookmark only when the config row still
        // matches the live path — a mid-swap rollback can't recover the old path's
        // bookmark, so it rolls back bookmark-less and the missing-file UX takes over.
        let configuredByID = Dictionary(
            (instance.configuration.removableMedia ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var rollbackLookup: [UUID: RemovableMediaItem] = [:]
        for info in tracked {
            let configured = configuredByID[info.id]
            // Start from the persisted entry so its label and note survive the
            // rollback; only the fields the live state actually answers for
            // (path, readOnly, and the bookmark's validity) are overridden.
            var copy =
                configured
                ?? RemovableMediaItem(id: info.id, path: info.path, readOnly: info.readOnly, bookmark: nil)
            copy.path = info.path
            copy.readOnly = info.readOnly
            copy.bookmark = configured?.path == info.path ? configured?.bookmark : nil
            rollbackLookup[info.id] = copy
        }
        for item in target where rollbackLookup[item.id] == nil {
            rollbackLookup[item.id] = item
        }

        var toDetach: [USBDeviceInfo] = []
        var toAttach: [RemovableMediaItem] = []
        for trackedItem in tracked {
            guard let desired = targetByID[trackedItem.id] else {
                toDetach.append(trackedItem)
                continue
            }
            if desired.path != trackedItem.path || desired.readOnly != trackedItem.readOnly {
                toDetach.append(trackedItem)
                toAttach.append(desired)
            }
        }
        // Iterate the deduped dictionary, not `target`, so a config with
        // duplicate ids can't queue two attaches for the same UUID.
        for targetItem in targetByID.values where trackedByID[targetItem.id] == nil {
            toAttach.append(targetItem)
        }

        // Apply detaches first so duplicate-UUID conflicts can't fire when
        // a swap reuses an id with a different attachment.
        for device in toDetach {
            do {
                try await lifecycle.detachUSBDevice(device, from: instance)
                instance.sessionContext?.fileAccess.releaseHotAttach(id: device.id)
            } catch USBDeviceError.noVirtualMachine {
                Self.logger.notice(
                    "VM '\(instance.name, privacy: .public)' torn down during media detach; abandoning reconcile"
                )
                return
            } catch USBDeviceError.deviceNotFound {
                // The lifecycle layer's `removeAll` is skipped when the framework call
                // throws, so clear stale tracking explicitly here.
                Self.logger.notice(
                    "Removable media '\(device.displayName, privacy: .public)' was already gone on '\(instance.name, privacy: .public)' (deviceNotFound); clearing tracking"
                )
                instance.sessionContext?.liveRemovableMedia.removeAll { $0.id == device.id }
                instance.sessionContext?.fileAccess.releaseHotAttach(id: device.id)
            } catch {
                Self.logger.error(
                    "Removable media detach failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                reconcileConfigToLiveState(for: instance, lookup: rollbackLookup)
                presentError(error)
                return
            }
        }

        for item in toAttach {
            do {
                // The scope must stay live while the service resolves the path and
                // opens the attachment; on success it is registered with the instance
                // (released at detach or teardown), and released by deinit if it throws.
                let scope = item.bookmark.flatMap { ScopedAccess(bookmark: $0) }
                _ = try await lifecycle.attachUSBDevice(
                    diskImagePath: item.path,
                    readOnly: item.readOnly,
                    desiredUUID: item.id,
                    resolvedURL: scope?.url,
                    to: instance
                )
                if let scope {
                    instance.sessionContext?.fileAccess.addHotAttach(id: item.id, scope)
                }
                Self.logger.notice(
                    "Attached removable media '\(item.label, privacy: .public)' on '\(instance.name, privacy: .public)' (readOnly: \(item.readOnly, privacy: .public))"
                )
            } catch USBDeviceError.noVirtualMachine {
                Self.logger.notice(
                    "VM '\(instance.name, privacy: .public)' torn down during media attach; abandoning reconcile"
                )
                return
            } catch {
                Self.logger.error(
                    "Removable media attach failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                reconcileConfigToLiveState(for: instance, lookup: rollbackLookup)
                presentError(error)
                return
            }
        }
    }

    /// Rolls `instance.configuration.removableMedia` back to whatever is
    /// actually attached in `liveRemovableMedia`.
    ///
    /// The write bypasses `updateConfiguration` to avoid re-entering the reconcile
    /// pipeline — the rolled-back state is the destination, not a retry.
    private func reconcileConfigToLiveState(
        for instance: VMInstance,
        lookup: [UUID: RemovableMediaItem]
    ) {
        let rolled = instance.liveRemovableMedia.compactMap { lookup[$0.id] }
        var newConfig = instance.configuration
        newConfig.removableMedia = rolled.isEmpty ? nil : rolled
        guard newConfig != instance.configuration else { return }
        instance.configuration = newConfig
        saveConfiguration(for: instance)
        Self.logger.notice(
            "Rolled removable media config for '\(instance.name, privacy: .public)' back to live state after reconcile error"
        )
    }

    // MARK: - Sleep/Wake

    /// Pauses all running VMs before system sleep, tracking which were auto-paused so
    /// only those are resumed on wake.
    func pauseAllForSleep() async {
        let runningInstances = instances.filter { $0.status == .running }
        guard !runningInstances.isEmpty else {
            Self.logger.debug("pauseAllForSleep: no running VMs, nothing to pause")
            return
        }

        Self.logger.notice("System going to sleep — pausing \(runningInstances.count, privacy: .public) running VM(s)")

        var failedNames: [String] = []
        for instance in runningInstances {
            do {
                try await lifecycle.pause(instance)
                sleepPausedInstanceIDs.insert(instance.id)
                Self.logger.debug(
                    "Paused '\(instance.name, privacy: .public)' for sleep (status: \(instance.status.displayName, privacy: .public))"
                )
            } catch {
                Self.logger.error(
                    "Failed to pause '\(instance.name, privacy: .public)' for sleep: \(error.localizedDescription, privacy: .public)"
                )
                failedNames.append(instance.name)
            }
        }
        if !failedNames.isEmpty {
            presentError(SleepWakeError.pauseFailed(vmNames: failedNames))
        }
    }

    /// Resumes only VMs that were auto-paused by `pauseAllForSleep()`.
    func resumeAllAfterWake() async {
        let idsToResume = sleepPausedInstanceIDs
        sleepPausedInstanceIDs.removeAll()
        guard !idsToResume.isEmpty else {
            Self.logger.debug("resumeAllAfterWake: no sleep-paused VMs to resume")
            return
        }

        let instancesToResume = instances.filter { idsToResume.contains($0.id) && $0.status == .paused }
        guard !instancesToResume.isEmpty else { return }

        Self.logger.notice("System woke up — resuming \(instancesToResume.count, privacy: .public) sleep-paused VM(s)")

        var failedNames: [String] = []
        for instance in instancesToResume {
            do {
                try await lifecycle.resume(instance)
                Self.logger.debug(
                    "Resumed '\(instance.name, privacy: .public)' after wake (status: \(instance.status.displayName, privacy: .public))"
                )
            } catch {
                Self.logger.error(
                    "Failed to resume '\(instance.name, privacy: .public)' after wake: \(error.localizedDescription, privacy: .public)"
                )
                failedNames.append(instance.name)
            }
        }
        if !failedNames.isEmpty {
            presentError(SleepWakeError.resumeFailed(vmNames: failedNames))
        }
    }

    private func startSleepWatcher() {
        let watcher = SystemSleepWatcher(
            onSleep: { [weak self] in
                await self?.pauseAllForSleep()
            },
            onWake: { [weak self] in
                await self?.resumeAllAfterWake()
            }
        )
        watcher.start()
        sleepWatcher = watcher
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
                let initialStatus = Self.initialStatus(for: config, layout: layout)
                let instance = VMInstance(
                    configuration: config,
                    bundleURL: bundleURL,
                    status: initialStatus,
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
                logDuplicateMACAddressHolders()
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

    /// Error type for sleep/wake lifecycle failures.
    private enum SleepWakeError: LocalizedError {
        case pauseFailed(vmNames: [String])
        case resumeFailed(vmNames: [String])

        var errorDescription: String? {
            switch self {
            case .pauseFailed(let vmNames):
                assert(!vmNames.isEmpty, "pauseFailed requires at least one VM name")
                return
                    "Failed to pause the following VMs before sleep: \(vmNames.joined(separator: ", ")). They may experience data corruption."
            case .resumeFailed(let vmNames):
                assert(!vmNames.isEmpty, "resumeFailed requires at least one VM name")
                return
                    "Failed to resume the following VMs after wake: \(vmNames.joined(separator: ", ")). You may need to restart them manually."
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
