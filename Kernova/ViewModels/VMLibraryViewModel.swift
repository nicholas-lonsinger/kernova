import Foundation
import KernovaKit
import Virtualization
import os

/// The AppKit adapter over ``VMCommandCore``: the sheets and alerts that gather
/// consent for a verb, the routing of a refused verb to the right surface, the
/// inline-rename editing state, and the settings edits no automation surface
/// speaks yet.
///
/// It runs no verb itself. Each method here does three things and stops: show
/// the sheet if one is owed, call the facade with explicit consent, and route
/// whatever ``CommandError`` comes back through ``present(_:for:)``.
///
/// Owns the library and the core, routes ``VMLibrary/onFailure`` and the core's
/// own failures to the presenter, and forwards the library's reads so a view
/// controller holding a view model still sees one surface.
@MainActor
@Observable
final class VMLibraryViewModel {
    nonisolated private static let logger = Logger(subsystem: "app.kernova", category: "VMLibraryViewModel")

    // MARK: - Services

    /// Which VMs exist, and everything that keeps that set in step with disk.
    let library: VMLibrary

    /// Every VM verb, headless. The one path from this adapter to a VM.
    let commands: VMCommandCore

    let storageService: any VMStorageProviding
    let diskImageService: any DiskImageProviding
    let snapshotStore: any VMSnapshotStoring
    let lifecycle: VMLifecycleCoordinator

    private let fileSystem: any FileSystemOperating

    private let preferences: AppPreferences

    // MARK: - Library Forwarding

    // Reads and library-level operations, forwarded verbatim so every existing
    // holder of a view model keeps working. Observation carries through the
    // computed accessors, which read the library's own stored properties.
    // Nothing here is a VM verb; each is documented on ``VMLibrary``.

    var instances: [VMInstance] {
        get { library.instances }
        set { library.instances = newValue }
    }

    var selectedID: UUID? {
        get { library.selectedID }
        set { library.selectedID = newValue }
    }

    var selectedInstance: VMInstance? { library.selectedInstance }

    var hasLoadedLibrary: Bool { library.hasLoadedLibrary }

    var hasPreparing: Bool { library.hasPreparing }

    var hasUninterruptibleWork: Bool { library.hasUninterruptibleWork }

    var hasSaveInFlight: Bool { library.hasSaveInFlight }

    var hasRevertInFlight: Bool { library.hasRevertInFlight }

    var sleepPausedInstanceIDs: Set<UUID> {
        get { library.sleepPausedInstanceIDs }
        set { library.sleepPausedInstanceIDs = newValue }
    }

    func isBusy(_ instance: VMInstance) -> Bool { library.isBusy(instance) }

    func startLibrary() async { await library.startLibrary() }

    func loadVMs() async { await library.loadVMs() }

    func reconcileWithDisk() { library.reconcileWithDisk() }

    func moveVM(fromOffsets source: IndexSet, toOffset destination: Int) {
        library.moveVM(fromOffsets: source, toOffset: destination)
    }

    func waitForRevertsToSettle() async { await library.waitForRevertsToSettle() }

    func vmNamesSharingMACAddress(with instance: VMInstance) -> [String] {
        library.vmNamesSharingMACAddress(with: instance)
    }

    @discardableResult
    func saveConfiguration(for instance: VMInstance) -> Bool {
        library.saveConfiguration(for: instance)
    }

    @discardableResult
    func updateConfiguration(
        of instance: VMInstance,
        mutate: (inout VMConfiguration) -> Void
    ) -> Bool {
        library.updateConfiguration(of: instance, mutate: mutate)
    }

    // MARK: - Command Forwarding

    // Headless reads and gates the UI enables its commands from, each
    // documented on ``VMCommandCore``.

    func canTakeSnapshot(_ instance: VMInstance) -> Bool { commands.canTakeSnapshot(instance) }

    func canRevertToSnapshot(_ instance: VMInstance) -> Bool {
        commands.canRevertToSnapshot(instance)
    }

    func canDeleteSnapshots(_ instance: VMInstance) -> Bool { commands.canDeleteSnapshots(instance) }

    func canDeleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) -> Bool {
        commands.canDeleteSnapshot(instance, snapshot: snapshot)
    }

    func reloadSnapshots(for instance: VMInstance) { commands.reloadSnapshots(for: instance) }

    func snapshotOnDiskBytes(for instance: VMInstance) async -> [UUID: UInt64] {
        await commands.snapshotOnDiskBytes(for: instance)
    }

    func bundledDisks(for instance: VMInstance) -> [StorageDisk] {
        commands.bundledDisks(for: instance)
    }

    func isMainDisk(_ disk: StorageDisk, of instance: VMInstance) -> Bool {
        commands.isMainDisk(disk, of: instance)
    }

    func externalAttachments(for instance: VMInstance) -> [ExternalAttachment] {
        commands.externalAttachments(for: instance)
    }

    func externalAttachmentsResolvingExistence(for instance: VMInstance) async
        -> [ExternalAttachment]
    {
        await commands.externalAttachmentsResolvingExistence(for: instance)
    }

    func sharingVMNames(forPath path: String, excluding instance: VMInstance) -> [String] {
        commands.sharingVMNames(forPath: path, excluding: instance)
    }

    func isGuestAgentInstaller(_ item: RemovableMediaItem) -> Bool {
        commands.isGuestAgentInstaller(item)
    }

    func isGuestAgentInstallerMounted(on instance: VMInstance) -> Bool {
        commands.isGuestAgentInstallerMounted(on: instance)
    }

    /// Cancels a guest setup from the confirmation `GuestSetupProgressViewController`
    /// already gathered, so this always calls the facade pre-confirmed.
    func cancelGuestSetup(_ instance: VMInstance) {
        do {
            try commands.cancelGuestSetup(.id(instance.id), confirmed: true)
        } catch let error as CommandError {
            // Setup finishing between the button appearing and the click is a
            // normal race, not something to alert the user about.
            Self.logger.notice(
                "Nothing to cancel for '\(instance.name, privacy: .public)': \(error.message, privacy: .public)"
            )
        } catch {
            surfaceError(error.localizedDescription)
        }
    }

    // MARK: - State

    /// Whether the sidebar's guest-agent install nudge is turned off for every
    /// VM, overriding each VM's own `agentInstallNudgeDismissed` flag without
    /// touching it.
    ///
    /// The single write path for `AppPreferences.agentInstallPromptDisabled`,
    /// mirrored here because the sidebar and the VM Settings pane refresh from
    /// `withObservationTracking`, which a bare `UserDefaults` read never wakes.
    var agentInstallPromptDisabled: Bool {
        didSet {
            guard agentInstallPromptDisabled != oldValue else { return }
            Self.logger.notice(
                "Setting app-wide agent install prompt disabled=\(self.agentInstallPromptDisabled, privacy: .public)"
            )
            preferences.agentInstallPromptDisabled = agentInstallPromptDisabled
        }
    }

    /// Whether closing the last window (or a GUI-origin quit) leaves Kernova
    /// resident in the status bar instead of quitting it.
    ///
    /// The single write path for `AppPreferences.keepInMenuBarOnQuit`, mirrored
    /// here because `AppDelegate` reconciles the status item and the activation
    /// policy from `withObservationTracking`, which a bare `UserDefaults` read
    /// never wakes.
    var keepInMenuBarOnQuit: Bool {
        didSet {
            guard keepInMenuBarOnQuit != oldValue else { return }
            Self.logger.notice(
                "Setting keep in status bar=\(self.keepInMenuBarOnQuit, privacy: .public)"
            )
            preferences.keepInMenuBarOnQuit = keepInMenuBarOnQuit
        }
    }

    /// Presentation delegate for alerts, sheets, and the creation wizard.
    ///
    /// Errors raised before a presenter is attached — the library read starts in
    /// `applicationWillFinishLaunching`, ahead of any window — are buffered and
    /// flushed when one is set.
    @ObservationIgnored weak var presenter: (any VMLibraryPresenting)? {
        didSet {
            guard presenter != nil, !bufferedErrors.isEmpty else { return }
            let buffered = bufferedErrors
            bufferedErrors.removeAll()
            buffered.forEach { presenter?.presentError($0.message, title: $0.title) }
        }
    }

    @ObservationIgnored private var bufferedErrors: [(title: String, message: String)] = []

    var activeRename: RenameTarget?

    /// Called when a VM with a non-inline `displayPreference` is about to start or resume,
    /// allowing the app delegate to pre-create the display window with a spinner.
    @ObservationIgnored var onOpenDisplayWindow: ((VMInstance) -> Void)?

    /// Measures the window or screen a starting VM's display will occupy, for
    /// `displaySizesToWindow`.
    @ObservationIgnored weak var displayBootGeometryProvider: (any DisplayBootGeometryProviding)? {
        didSet { commands.displayBootGeometryProvider = displayBootGeometryProvider }
    }

    // MARK: - Initialization

    init(
        storageService: any VMStorageProviding = VMStorageService(),
        diskImageService: any DiskImageProviding = DiskImageService(),
        snapshotStore: any VMSnapshotStoring = VMSnapshotStore(),
        virtualizationService: any VirtualizationProviding = VirtualizationService(),
        installService: any MacOSInstallProviding = MacOSInstallService(),
        ipswService: any IPSWProviding = IPSWService(),
        usbDeviceService: any USBDeviceProviding = USBDeviceService(),
        linuxImageResolveService: any LinuxImageResolving = LinuxImageResolveService(),
        downloadService: any Downloading = DownloadService(),
        fileSystem: any FileSystemOperating = FileManager.default,
        downloadsDirectory: URL? = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first,
        preferences: AppPreferences = .shared,
        vmnetNetworks: any VmnetNetworkProviding = VmnetNetworkService.shared,
        isVMNetworkingEntitled: Bool = EntitlementService.shared.hasVMNetworking
    ) {
        self.storageService = storageService
        self.diskImageService = diskImageService
        self.snapshotStore = snapshotStore
        self.fileSystem = fileSystem
        self.preferences = preferences
        self.agentInstallPromptDisabled = preferences.agentInstallPromptDisabled
        self.keepInMenuBarOnQuit = preferences.keepInMenuBarOnQuit
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: virtualizationService,
            installService: installService,
            ipswService: ipswService,
            usbDeviceService: usbDeviceService,
            linuxImageResolveService: linuxImageResolveService,
            downloadService: downloadService,
            fileSystem: fileSystem,
            downloadsDirectory: downloadsDirectory
        )
        self.lifecycle = lifecycle
        let library = VMLibrary(
            storageService: storageService,
            snapshotStore: snapshotStore,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: vmnetNetworks,
            isVMNetworkingEntitled: isVMNetworkingEntitled
        )
        self.library = library
        self.commands = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storageService,
            snapshotStore: snapshotStore,
            fileSystem: fileSystem,
            preferences: preferences
        )

        library.onFailure = { [weak self] title, message in
            self?.surfaceError(message, title: title)
        }
        library.onAgentBecameCurrent = { [weak self] instance in
            self?.unmountGuestAgentInstaller(from: instance)
        }
        // The same routing a call site gets, so a failure nobody awaited still
        // reaches the sheet or the recovery alert its type asks for.
        commands.onFailure = { [weak self] failure, instance in
            self?.present(failure, for: instance)
        }
        commands.surfaceDisplay = { [weak self] instance in
            self?.surfaceDisplay(for: instance)
        }
    }

    // MARK: - Create

    /// Creates a VM bundle and disk image from a wizard model, optionally
    /// auto-starting it.
    ///
    /// The error is returned rather than presented so the wizard host can show it on
    /// the wizard's own sheet and keep it open for a retry.
    @discardableResult
    func createVM(from wizard: VMCreationViewModel) async -> Result<Void, Error> {
        do {
            var config = wizard.buildConfiguration()

            // Persist the setup intent so the next Start can drive the pipeline
            // without the wizard: a macOS install, or the download of a Linux
            // installer image the user picked from the catalog.
            switch config.guestOS {
            case .macOS:
                config.installContext = wizard.buildInstallContext()
            case .linux:
                config.linuxInstallContext = wizard.buildLinuxInstallContext()
            }

            let bundleURL = try storageService.createVMBundle(for: config)
            let layout = VMBundleLayout(bundleURL: bundleURL)
            let initialStatus = VMLibrary.initialStatus(for: config, layout: layout)
            let instance = VMInstance(
                configuration: config, bundleURL: bundleURL, status: initialStatus,
                preferences: preferences)
            library.wirePersistence(for: instance)

            try await diskImageService.createDiskImage(
                at: instance.diskImageURL,
                sizeInGB: config.diskSizeInGB
            )

            instances.append(instance)
            library.persistOrder()
            selectedID = instance.id

            Self.logger.notice(
                "Created VM '\(config.name, privacy: .public)' (status: \(initialStatus.displayName, privacy: .public))"
            )

            if wizard.startAfterCreate {
                Self.logger.notice(
                    "Auto-starting VM '\(config.name, privacy: .public)' from wizard"
                )
                await start(instance)
            }
            return .success(())
        } catch {
            Self.logger.error("Failed to create VM: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    // MARK: - Lifecycle

    /// Surfaces the display a start/resume lands on: the detached window for
    /// pop-out/fullscreen VMs, else keyboard focus in the inline guest display.
    private func surfaceDisplay(for instance: VMInstance) {
        if instance.configuration.displayPreference != .inline {
            onOpenDisplayWindow?(instance)
        } else {
            presenter?.focusGuestDisplay(for: instance)
        }
    }

    func start(_ instance: VMInstance, bootIntoRecovery: Bool = false) async {
        await run(on: instance) {
            try await self.commands.start(.id(instance.id), recovery: bootIntoRecovery)
        }
    }

    /// Confirmed action of the start-failed alert: detach the failing
    /// attachment (file untouched) and immediately retry the start.
    ///
    /// No-ops if the VM is gone or the entry has already been removed: alerts are
    /// serialized, so this confirmation can arrive long after the failed start, and
    /// retrying after a removal that found nothing would re-raise the same failure.
    func removeStartFailedAttachmentAndStart(
        _ failure: StartFailedAttachment, on instance: VMInstance
    ) async {
        guard instances.contains(where: { $0.id == instance.id }) else {
            Self.logger.debug(
                "Ignoring start-failed removal for already-removed VM '\(instance.name, privacy: .public)'"
            )
            return
        }

        let removed: Bool
        switch failure.kind {
        case .storageDisk:
            if let disk = commands.storageDisk(id: failure.id, on: instance) {
                _ = removeStorageDisk(disk, from: instance, trashFile: false)
                removed = true
            } else {
                removed = false
            }
        case .removableMedia:
            if let item = (instance.configuration.removableMedia ?? [])
                .first(where: { $0.id == failure.id })
            {
                removeRemovableMedia(item, from: instance, trashFile: false)
                removed = true
            } else {
                removed = false
            }
        }

        guard removed else {
            Self.logger.notice(
                "Failed attachment '\(failure.label, privacy: .public)' already gone from '\(instance.name, privacy: .public)'; not retrying start"
            )
            return
        }
        Self.logger.notice(
            "Removed failed attachment '\(failure.label, privacy: .public)' from '\(instance.name, privacy: .public)'; retrying start"
        )
        // A save file restores only into the exact device set it was saved
        // with, so it cannot outlive the removal — the alert disclosed the
        // discard before the user confirmed.
        if instance.hasSaveFile {
            instance.removeSaveFile()
            Self.logger.notice(
                "Discarded saved state for '\(instance.name, privacy: .public)' along with the removed attachment"
            )
            if instance.isColdPaused { instance.status = .stopped }
        }
        await start(instance)
    }

    func stop(_ instance: VMInstance) async {
        // Unconfirmed: a live-paused guest cannot take an ACPI shutdown, and
        // the core says so by refusing — which is what raises the sheet.
        await run(on: instance) {
            try await self.commands.stop(
                .id(instance.id), disposition: .graceful, confirmed: false)
        }
    }

    /// Resumes a paused VM then requests a graceful ACPI shutdown — the
    /// stop-paused sheet's default action.
    func resumeAndStop(_ instance: VMInstance) async {
        await run(on: instance) {
            try await self.commands.stop(
                .id(instance.id), disposition: .resumeThenShutDown, confirmed: true)
        }
    }

    func forceStop(_ instance: VMInstance) async {
        await run(on: instance) {
            try await self.commands.stop(.id(instance.id), disposition: .force, confirmed: true)
        }
    }

    /// Opens the Force Stop / Discard Saved State confirmation.
    func requestForceStop(_ instance: VMInstance) {
        presenter?.presentForceStop(for: instance)
    }

    /// Opens the confirmation for booting a stopped macOS guest into macOS
    /// Recovery.
    func requestStartInRecovery(_ instance: VMInstance) {
        presenter?.presentRecoveryBoot(for: instance)
    }

    func pause(_ instance: VMInstance) async {
        await run(on: instance) { try await self.commands.pause(.id(instance.id)) }
    }

    func resume(_ instance: VMInstance) async {
        await run(on: instance) { try await self.commands.resume(.id(instance.id)) }
    }

    func save(_ instance: VMInstance) async {
        await run(on: instance) { try await self.commands.suspend(.id(instance.id)) }
    }

    /// Saves VM state, throwing on failure (used by suspend-on-quit in AppDelegate).
    func trySave(_ instance: VMInstance) async throws {
        try await commands.suspend(.id(instance.id))
    }

    /// Force-stops a VM, throwing on failure (used by suspend-on-quit fallback in AppDelegate).
    func tryForceStop(_ instance: VMInstance) async throws {
        try await commands.stop(.id(instance.id), disposition: .force, confirmed: true)
    }

    // MARK: - Snapshots

    /// Opens the Take Snapshot sheet.
    func requestTakeSnapshot(_ instance: VMInstance) {
        guard canTakeSnapshot(instance) else { return }
        presenter?.presentTakeSnapshotSheet(for: instance)
    }

    /// Captures a snapshot from the Take Snapshot sheet's confirm.
    ///
    /// The returned Task lets tests await the capture.
    @discardableResult
    func takeSnapshot(_ instance: VMInstance, name: String, notes: String = "") -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            await self.run(on: instance) {
                _ = try await self.commands.takeSnapshot(
                    .id(instance.id), name: name, notes: notes)
            }
        }
    }

    /// Opens the revert confirmation.
    func requestRevert(_ instance: VMInstance, to snapshot: VMSnapshot) {
        guard canRevertToSnapshot(instance) else { return }
        presenter?.presentRevertSnapshot(snapshot, for: instance)
    }

    /// Reverts to `snapshot`, optionally check-pointing the current state
    /// first — the revert confirmation's two actions.
    func revert(
        _ instance: VMInstance, to snapshot: VMSnapshot, takingCheckpoint: Bool = false
    ) async {
        await run(on: instance) {
            try await self.commands.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, takingCheckpoint: takingCheckpoint,
                confirmed: true)
        }
    }

    /// Opens the delete-snapshot confirmation.
    func requestDeleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) {
        guard canDeleteSnapshot(instance, snapshot: snapshot) else {
            Self.logger.notice(
                "Refusing to delete snapshot '\(snapshot.name, privacy: .public)': it is the Ephemeral baseline of '\(instance.name, privacy: .public)'"
            )
            return
        }
        presenter?.presentDeleteSnapshot(snapshot, for: instance)
    }

    /// Trashes a snapshot's captured files and drops it from the manifest.
    ///
    /// The returned Task lets tests await the trash.
    @discardableResult
    func deleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            await self.run(on: instance) {
                try await self.commands.deleteSnapshot(
                    .id(instance.id), snapshot: snapshot.id, confirmed: true)
            }
        }
    }

    /// Renames a snapshot; an empty or unchanged name is a no-op.
    func renameSnapshot(_ snapshot: VMSnapshot, newName: String, on instance: VMInstance) {
        runSync(on: instance) {
            try self.commands.renameSnapshot(
                .id(instance.id), snapshot: snapshot.id, to: newName)
        }
    }

    /// Replaces a snapshot's note; an unchanged value is a no-op.
    func setSnapshotNotes(_ snapshot: VMSnapshot, notes: String, on instance: VMInstance) {
        runSync(on: instance) {
            try self.commands.setSnapshotNotes(
                .id(instance.id), snapshot: snapshot.id, notes: notes)
        }
    }

    // MARK: - Delete

    /// Opens the delete-VM sheet.
    ///
    /// `permanently` selects the destructive variant: `false` (the default) moves
    /// the bundle and the chosen externals to Trash, `true` deletes them
    /// immediately, bypassing it.
    func requestDelete(_ instance: VMInstance, permanently: Bool = false) {
        presenter?.presentDeleteSheet(for: instance, permanently: permanently)
    }

    /// Deletes the VM bundle and the chosen external files, either to the
    /// Trash or immediately (bypassing it).
    func delete(
        _ instance: VMInstance, deletingExternalIDs: Set<UUID> = [], permanently: Bool = false
    ) async {
        do {
            try await commands.delete(
                .id(instance.id), permanently: permanently, alsoRemoving: deletingExternalIDs,
                confirmed: true)
        } catch let error as CommandError {
            // A second sheet for a VM the first already removed, or one whose
            // state moved while the sheet was up: refused rather than run, and
            // there is nothing to tell the user about a delete they can retry.
            switch error {
            case .notFound, .invalidState, .busy:
                Self.logger.notice(
                    "Refusing delete of '\(instance.name, privacy: .public)': \(error.message, privacy: .public)"
                )
            default:
                present(error, for: instance)
            }
        } catch {
            surfaceError(error.localizedDescription)
        }
    }

    // MARK: - Import

    /// Filters `urls` to `.kernova` bundles and imports the batch.
    ///
    /// Each bundle's destination is reserved and its phantom row registered synchronously (see
    /// ``VMCommandCore/importVM(from:)``), so two overlapping triggers never collide on a
    /// destination name and never wait behind each other's copies.
    ///
    /// Returns whether any bundle was accepted for import — `true` means at least one
    /// bundle was reserved, not that every import will succeed.
    @discardableResult
    func importVMs(fromDroppedURLs urls: [URL]) -> Bool {
        let bundles = urls.filter { VMStorageService.isBundleURL($0) }
        guard !bundles.isEmpty else { return false }
        Self.logger.notice("Importing \(bundles.count, privacy: .public) bundle(s)")
        for url in bundles {
            runSync(on: nil) { _ = try self.commands.importVM(from: url) }
        }
        return true
    }

    #if DEBUG
    /// Test-only seam awaiting every in-flight preparing (clone/import) copy task.
    func awaitPreparingForTesting() async {
        for task in instances.compactMap({ $0.preparingState?.task }) {
            await task.value
        }
    }
    #endif

    // MARK: - Clone

    /// The Option-alternate Clone: performs the opposite of the
    /// `cloneGeneratesNewMachineID` preference for this one clone.
    func cloneVMWithOppositeMachineIdentity(_ instance: VMInstance) {
        cloneVM(instance, generateNewMachineID: !preferences.cloneGeneratesNewMachineID)
    }

    /// Clones `instance`. `generateNewMachineID: nil` follows the
    /// `cloneGeneratesNewMachineID` preference; the Option-alternate menu items
    /// pass the opposite explicitly via `cloneVMWithOppositeMachineIdentity`.
    func cloneVM(_ instance: VMInstance, generateNewMachineID: Bool? = nil) {
        let identity: CloneMachineIdentity
        switch generateNewMachineID {
        case .none: identity = .followPreference
        case .some(true): identity = .new
        case .some(false): identity = .keep
        }
        do {
            _ = try commands.clone(.id(instance.id), machineIdentity: identity)
        } catch let error as CommandError {
            if case .invalidState = error {
                Self.logger.debug(
                    "Clone skipped for '\(instance.name, privacy: .public)': status '\(instance.status.displayName, privacy: .public)' does not allow editing"
                )
            } else {
                present(error, for: instance)
            }
        } catch {
            surfaceError(error.localizedDescription)
        }
    }

    // MARK: - Cancel Preparing

    /// Opens the cancel-clone/import confirmation.
    func requestCancelPreparing(_ instance: VMInstance) {
        presenter?.presentCancelPreparing(for: instance)
    }

    /// Cancels an in-flight clone or import from that confirmation's confirm.
    func cancelPreparing(_ instance: VMInstance) {
        do {
            try commands.cancelPreparing(.id(instance.id), confirmed: true)
        } catch let error as CommandError {
            // The copy settled — or the row went — while the confirmation was
            // up. The operation the user asked to stop is already over.
            Self.logger.notice(
                "Nothing to cancel for '\(instance.name, privacy: .public)': \(error.message, privacy: .public)"
            )
        } catch {
            surfaceError(error.localizedDescription)
        }
    }

    // MARK: - Rename

    enum RenameTarget: Equatable {
        case sidebar(UUID)
        case detail(UUID)
    }

    /// One of the two inline-rename surfaces, without the instance baked in.
    ///
    /// Commit/cancel call sites pass the surface and the instance separately so an
    /// instance/target id mismatch is unrepresentable.
    enum RenameSurface {
        case sidebar
        case detail

        fileprivate func target(for instance: VMInstance) -> RenameTarget {
            switch self {
            case .sidebar: .sidebar(instance.id)
            case .detail: .detail(instance.id)
            }
        }
    }

    func renameVMInSidebar(_ instance: VMInstance) {
        Self.logger.debug("Starting sidebar rename for '\(instance.name, privacy: .public)'")
        activeRename = .sidebar(instance.id)
    }

    func renameVMInDetail(_ instance: VMInstance) {
        Self.logger.debug("Starting detail rename for '\(instance.name, privacy: .public)'")
        activeRename = .detail(instance.id)
    }

    /// Commits the rename text from one of the two rename surfaces.
    ///
    /// The marker is only cleared while it still belongs to `surface`'s rename of
    /// `instance`: a commit can fire from a field editor resigning *because* a rename
    /// just started on the other surface (its `makeFirstResponder` synchronously ends
    /// the pending session), and clearing unconditionally would wipe the newer
    /// rename's marker before its UI ever opened.
    func commitRename(for instance: VMInstance, newName: String, from surface: RenameSurface) {
        do {
            try commands.rename(.id(instance.id), to: newName)
        } catch let error as CommandError where error.isOperationFailure {
            // The configuration funnel already told the user the write failed;
            // the verb throws so a wire client hears about it, and a second
            // alert saying the same thing is not what the user needs.
            Self.logger.error(
                "Rename of '\(instance.name, privacy: .public)' did not persist: \(error.message, privacy: .public)"
            )
        } catch {
            present(error, for: instance)
        }
        clearRename(ifOwnedBy: surface.target(for: instance))
    }

    /// Cancels the rename that `surface` has open on `instance`, leaving a rename
    /// that has since moved to the other surface untouched.
    func cancelRename(for instance: VMInstance, from surface: RenameSurface) {
        clearRename(ifOwnedBy: surface.target(for: instance))
    }

    private func clearRename(ifOwnedBy target: RenameTarget) {
        if activeRename == target {
            activeRename = nil
        }
    }

    // MARK: - Clipboard Policy

    /// Carries an app-wide clipboard paste-ceiling change to every running VM.
    ///
    /// The ceiling lives in `AppPreferences`, so it produces no `VMConfiguration`
    /// diff for `applyLivePolicy` to carry. Two things need it: the guest, which
    /// enforces host→guest pastes against its own copy, and any passthrough
    /// session holding an offer the old ceiling refused. Instances with neither
    /// no-op.
    func applyClipboardPasteLimitChange() {
        for instance in instances {
            instance.resendAgentPolicy()
            instance.republishPassthroughIfCeilingRaised()
        }
    }

    // MARK: - Guest Agent Installer

    /// Mounts the bundled `KernovaMacOSAgent.dmg` as a read-only USB device so
    /// the user can run `install.command` inside the guest.
    ///
    /// On mount — and when the disk is already mounted — asks the presenter to show
    /// the next-step alert, so every entry point gives the user feedback. The mount
    /// itself is a no-op when the DMG is already in this VM's `removableMedia` list.
    ///
    /// A guest taking the disk over virtio already has it, attached for the whole
    /// session, so there the alert is the entire action.
    func mountGuestAgentInstaller(
        on instance: VMInstance, purpose: GuestAgentInstallerPurpose = .install
    ) {
        guard let url = KernovaMacOSAgentInfo.installerDiskImageURL else {
            Self.logger.fault("Guest agent installer DMG missing from app bundle")
            assertionFailure("KernovaMacOSAgent.dmg missing — check 'Package Guest Agent DMG' build phase outputs")
            return
        }
        let delivery = GuestAgentDiskDelivery.mode(for: instance.configuration)
        guard delivery == .usb else {
            Self.logger.debug(
                "Guest agent disk reaches '\(instance.name, privacy: .public)' over virtio; showing next steps only")
            presenter?.presentInstallerMounted(vmName: instance.name, purpose: purpose, delivery: delivery)
            return
        }
        if isGuestAgentInstallerMounted(on: instance) {
            Self.logger.debug("Guest agent installer already mounted on '\(instance.name, privacy: .public)'")
            presenter?.presentInstallerMounted(vmName: instance.name, purpose: purpose, delivery: delivery)
            return
        }
        let path = url.path(percentEncoded: false)
        Self.logger.notice("Mounting guest agent installer on '\(instance.name, privacy: .public)'")
        updateConfiguration(of: instance) { config in
            config.removableMedia =
                (config.removableMedia ?? []) + [
                    RemovableMediaItem(
                        path: path,
                        readOnly: true,
                        label: KernovaMacOSAgentInfo.diskLabel
                    )
                ]
        }
        presenter?.presentInstallerMounted(vmName: instance.name, purpose: purpose, delivery: delivery)
    }

    /// Marks this VM's `.waiting` install nudge as dismissed and persists the choice.
    ///
    /// `.outdated`, `.unresponsive`, and `.expectedMissing` still surface — those imply
    /// something more urgent than "you could install this".
    func dismissAgentInstallNudge(for instance: VMInstance) {
        setAgentInstallNudgeDismissed(true, for: instance)
    }

    /// Sets whether this VM's agent-install nudge is dismissed and persists the
    /// choice.
    ///
    /// The single write path for the per-VM `agentInstallNudgeDismissed` flag:
    /// `true` silences the `.waiting` nudge, `false` re-arms it.
    func setAgentInstallNudgeDismissed(_ dismissed: Bool, for instance: VMInstance) {
        guard instance.configuration.agentInstallNudgeDismissed != dismissed else { return }
        Self.logger.notice(
            "Setting install-agent nudge dismissed=\(dismissed, privacy: .public) for '\(instance.name, privacy: .public)'"
        )
        updateConfiguration(of: instance) { $0.agentInstallNudgeDismissed = dismissed }
    }

    /// Re-arms the agent-install nudge everywhere: clears the app-wide
    /// suppression *and* every VM's dismissed flag, so each VM's `.waiting`
    /// nudge can surface again.
    ///
    /// Each VM's flag lives in its own bundle configuration and is persisted
    /// individually; VMs already armed no-op.
    func resetAllAgentInstallNudges() {
        agentInstallPromptDisabled = false
        for instance in instances {
            setAgentInstallNudgeDismissed(false, for: instance)
        }
    }

    /// Removes the bundled guest agent installer entry from
    /// `removableMedia` if currently present.
    ///
    /// The reconcile flow performs the runtime detach.
    func unmountGuestAgentInstaller(from instance: VMInstance) {
        guard let url = KernovaMacOSAgentInfo.installerDiskImageURL else { return }
        guard isGuestAgentInstallerMounted(on: instance) else { return }
        let path = url.path(percentEncoded: false)
        Self.logger.notice("Unmounting guest agent installer from '\(instance.name, privacy: .public)'")
        updateConfiguration(of: instance) { config in
            let pruned = (config.removableMedia ?? []).filter { $0.path != path }
            config.removableMedia = pruned.isEmpty ? nil : pruned
        }
    }

    // MARK: - Storage Disks

    /// Removes a storage disk entry from the configuration.
    ///
    /// When `trashFile` is `true` the underlying file is moved to Trash — internal
    /// (bundle-owned) disks resolve against `instance.bundleURL`, external disks
    /// against their absolute path; an already-missing file is logged and swallowed.
    ///
    /// `FileManager.trashItem` can block for seconds on slow or unresponsive volumes,
    /// so the trash runs in `Task.detached`. The returned Task lets tests await it.
    @discardableResult
    func removeStorageDisk(
        _ disk: StorageDisk, from instance: VMInstance, trashFile: Bool
    ) -> Task<Void, Never>? {
        updateConfiguration(of: instance) { config in
            var disks = config.storageDisks ?? VMCommandCore.defaultStorageDisks(for: instance)
            disks.removeAll { $0.id == disk.id }
            config.storageDisks = disks.isEmpty ? nil : disks
        }

        guard trashFile else { return nil }
        // Never trash a file another VM still references; only external disks can be
        // shared, since bundle-relative paths are per-VM.
        if !disk.isInternal, !sharingVMNames(forPath: disk.path, excluding: instance).isEmpty {
            Self.logger.notice(
                "Kept shared disk '\(disk.label, privacy: .public)' — still used by another VM; removed entry only"
            )
            return nil
        }
        let diskURL: URL =
            disk.isInternal
            ? instance.bundleURL.appendingPathComponent(disk.path)
            : URL(fileURLWithPath: disk.path)
        let label = disk.label
        let vmName = instance.name
        let bookmark = disk.isInternal ? nil : disk.bookmark
        let fileSystem = fileSystem
        return Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try SecurityScopedBookmark.withResolvedURL(bookmark: bookmark, fallback: diskURL) {
                    try fileSystem.trashItem(at: $0)
                }
                Self.logger.notice(
                    "Trashed disk '\(label, privacy: .public)' for VM '\(vmName, privacy: .public)'"
                )
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                Self.logger.notice(
                    "Disk file already gone for '\(label, privacy: .public)' (\(diskURL.lastPathComponent, privacy: .public)); skipping trash"
                )
            } catch {
                let message = error.localizedDescription
                Self.logger.warning(
                    "Failed to trash disk '\(label, privacy: .public)' (\(diskURL.lastPathComponent, privacy: .public)): \(message, privacy: .public)"
                )
                await MainActor.run { [weak self] in
                    self?.surfaceError(message)
                }
            }
        }
    }

    /// Renames a storage disk's user-facing label.
    ///
    /// The label is cosmetic — the virtio block identifier derives from the disk's
    /// UUID and the backing file keeps its UUID name — so renaming is safe for any
    /// disk including the main disk. Whitespace is trimmed and an empty result
    /// ignored. Duplicate labels are allowed on an explicit rename; only
    /// machine-generated defaults are uniqued.
    func renameStorageDisk(_ disk: StorageDisk, newLabel: String, on instance: VMInstance) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateConfiguration(of: instance) { config in
            var disks = config.storageDisks ?? VMCommandCore.defaultStorageDisks(for: instance)
            guard let index = disks.firstIndex(where: { $0.id == disk.id }) else { return }
            disks[index].label = trimmed
            config.storageDisks = disks
        }
    }

    /// Renames a removable medium's user-facing label.
    ///
    /// Safe while the VM is running: the live reconciliation only detaches and
    /// reattaches when `path` or `readOnly` differs, so a label-only edit leaves the
    /// medium mounted. Whitespace is trimmed and an empty result ignored.
    func renameRemovableMedia(
        _ item: RemovableMediaItem, newLabel: String, on instance: VMInstance
    ) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateConfiguration(of: instance) { config in
            var items = config.removableMedia ?? []
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index].label = trimmed
            config.removableMedia = items.isEmpty ? nil : items
        }
    }

    /// Replaces a storage disk's note; an unchanged value is a no-op.
    ///
    /// Unlike a label, an empty note is a legitimate value — it clears the
    /// note. Leading and trailing whitespace is trimmed; interior newlines are
    /// kept.
    func setStorageDiskNotes(_ disk: StorageDisk, notes: String, on instance: VMInstance) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != disk.notes else { return }
        updateConfiguration(of: instance) { config in
            var disks = config.storageDisks ?? VMCommandCore.defaultStorageDisks(for: instance)
            guard let index = disks.firstIndex(where: { $0.id == disk.id }) else { return }
            disks[index].notes = trimmed
            config.storageDisks = disks
        }
    }

    /// Replaces a removable medium's note; an unchanged value is a no-op.
    ///
    /// Safe while the VM is running: the live reconciliation only detaches and
    /// reattaches when `path` or `readOnly` differs, so a note-only edit leaves
    /// the medium mounted. Unlike a label, an empty note is a legitimate value —
    /// it clears the note. Leading and trailing whitespace is trimmed; interior
    /// newlines are kept.
    func setRemovableMediaNotes(_ item: RemovableMediaItem, notes: String, on instance: VMInstance) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != item.notes else { return }
        updateConfiguration(of: instance) { config in
            var items = config.removableMedia ?? []
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index].notes = trimmed
            config.removableMedia = items.isEmpty ? nil : items
        }
    }

    /// Removes a removable media entry from the configuration.
    ///
    /// When `trashFile` is `true` the file at the item's absolute path is moved to
    /// Trash — every removable item is a user-picked external file. Missing files are
    /// swallowed at `.notice` because removable media are often transient.
    ///
    /// `trashItem` succeeds even while the VM still holds the file open, so this
    /// doesn't wait for the hot-detach. The returned Task lets tests await it.
    @discardableResult
    func removeRemovableMedia(
        _ item: RemovableMediaItem, from instance: VMInstance, trashFile: Bool
    ) -> Task<Void, Never>? {
        updateConfiguration(of: instance) { config in
            var items = config.removableMedia ?? []
            items.removeAll { $0.id == item.id }
            config.removableMedia = items.isEmpty ? nil : items
        }

        guard trashFile else { return nil }
        // The bundled Guest Agent installer is app-owned: removing it only detaches
        // the entry — trashing it would corrupt the app bundle for every VM.
        if isGuestAgentInstaller(item) {
            Self.logger.notice(
                "Kept Guest Agent installer '\(item.label, privacy: .public)' — app-owned; removed entry only"
            )
            return nil
        }
        // Never trash a file another VM still references.
        if !sharingVMNames(forPath: item.path, excluding: instance).isEmpty {
            Self.logger.notice(
                "Kept shared media '\(item.label, privacy: .public)' — still used by another VM; removed entry only"
            )
            return nil
        }
        let url = URL(fileURLWithPath: item.path)
        let label = item.label
        let vmName = instance.name
        let bookmark = item.bookmark
        let fileSystem = fileSystem
        return Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try SecurityScopedBookmark.withResolvedURL(bookmark: bookmark, fallback: url) {
                    try fileSystem.trashItem(at: $0)
                }
                Self.logger.notice(
                    "Trashed removable media '\(label, privacy: .public)' for VM '\(vmName, privacy: .public)'"
                )
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                Self.logger.notice(
                    "Removable media file already gone for '\(label, privacy: .public)' (\(url.lastPathComponent, privacy: .public)) on VM '\(vmName, privacy: .public)'; skipping trash"
                )
            } catch {
                let message = error.localizedDescription
                Self.logger.warning(
                    "Failed to trash removable media '\(label, privacy: .public)' (\(url.lastPathComponent, privacy: .public)): \(message, privacy: .public)"
                )
                await MainActor.run { [weak self] in
                    self?.surfaceError(message)
                }
            }
        }
    }

    /// Creates a new ASIF disk image inside the VM bundle and adds it to
    /// `storageDisks`.
    ///
    /// The returned Task lets tests await completion of the async create + persist.
    @discardableResult
    func createStorageDisk(for instance: VMInstance, sizeInGB: Int) -> Task<Void, Never> {
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        let diskID = UUID()
        let diskURL = layout.additionalDiskURL(id: diskID)

        return Task {
            do {
                try FileManager.default.createDirectory(
                    at: layout.additionalDisksDirectoryURL, withIntermediateDirectories: true)

                try await diskImageService.createDiskImage(at: diskURL, sizeInGB: sizeInGB)

                // Bundle-relative so the entry travels with the bundle on clone / move.
                let relativePath = "AdditionalDisks/\(diskID.uuidString).asif"
                // Compute the unique default label *inside* the mutate closure against
                // the live config, so two rapid creates can't read the same snapshot
                // and pick the same "… 2" suffix.
                var createdLabel = "\(sizeInGB) GB Disk"
                updateConfiguration(of: instance) { config in
                    var disks =
                        config.storageDisks ?? VMCommandCore.defaultStorageDisks(for: instance)
                    let label = StorageDisk.uniqueLabel(
                        base: "\(sizeInGB) GB Disk", existingLabels: disks.map(\.label))
                    createdLabel = label
                    disks.append(
                        StorageDisk(
                            id: diskID,
                            path: relativePath,
                            readOnly: false,
                            label: label,
                            isInternal: true,
                            kind: .virtio
                        )
                    )
                    config.storageDisks = disks
                }

                Self.logger.notice(
                    "Created in-bundle storage disk '\(createdLabel, privacy: .public)' (\(sizeInGB, privacy: .public) GB) for VM '\(instance.name, privacy: .public)'"
                )
            } catch {
                // Only attempt cleanup when the write itself failed — earlier
                // phases throw before the destination file is touched.
                if case DiskImageError.writeFailed = error {
                    do {
                        try fileSystem.trashItem(at: diskURL)
                    } catch let cleanupError {
                        Self.logger.warning(
                            "Failed to clean up partial disk image at '\(diskURL.lastPathComponent, privacy: .public)': \(cleanupError.localizedDescription, privacy: .public)"
                        )
                    }
                }
                Self.logger.error(
                    "Failed to create storage disk for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                presentError(error)
            }
        }
    }

    /// Creates a new ASIF disk image at a user-chosen external location and
    /// attaches it to the VM as a hot-pluggable removable disk.
    ///
    /// The backing file is **not** bundle-owned: removal from the list does not trash
    /// it, and cloning the VM references the same path rather than duplicating it.
    func createRemovableMedia(for instance: VMInstance, sizeInGB: Int, destinationURL: URL) {
        Task {
            do {
                try await diskImageService.createDiskImage(at: destinationURL, sizeInGB: sizeInGB)

                // Bookmark after the write succeeds: the file must exist to be
                // bookmarked, and the write rides the still-live save-panel grant.
                let item = RemovableMediaItem(
                    path: destinationURL.path(percentEncoded: false),
                    readOnly: false,
                    label: destinationURL.deletingPathExtension().lastPathComponent,
                    bookmark: SecurityScopedBookmark.make(for: destinationURL)
                )
                updateConfiguration(of: instance) { config in
                    config.removableMedia = (config.removableMedia ?? []) + [item]
                }

                Self.logger.notice(
                    "Created removable disk '\(item.label, privacy: .public)' (\(sizeInGB, privacy: .public) GB) at '\(destinationURL.path, privacy: .public)' for VM '\(instance.name, privacy: .public)'"
                )
            } catch {
                // Only clean up when the write itself failed — earlier phases throw
                // before the destination is touched, and the path is user-chosen, so
                // trashing there could remove an unrelated pre-existing file.
                if case DiskImageError.writeFailed = error {
                    do {
                        try fileSystem.trashItem(at: destinationURL)
                    } catch let cleanupError {
                        Self.logger.warning(
                            "Failed to clean up partial removable disk at '\(destinationURL.lastPathComponent, privacy: .public)': \(cleanupError.localizedDescription, privacy: .public)"
                        )
                    }
                }
                Self.logger.error(
                    "Failed to create removable disk for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                presentError(error)
            }
        }
    }

    // MARK: - Launch Auto-Start

    /// Names of the macOS VMs marked to start automatically, in library order —
    /// which is the order ``startAutomaticVMsForLaunch()`` reaches them in.
    ///
    /// Feeds the Startup section's capacity warning: macOS caps how many macOS
    /// guests run at once, so a longer list than that cap cannot come up whole.
    var macOSVMNamesMarkedForAutoStart: [String] {
        instances
            .filter {
                $0.configuration.guestOS == .macOS
                    && $0.configuration.startsAutomaticallyOnLaunch
            }
            .map(\.name)
    }

    /// What the launch auto-start pass does with one VM.
    enum AutoStartStep: Equatable {
        case start
        case resume
        case skip
    }

    /// The pass's move for one VM, decided from state alone.
    ///
    /// A VM that has yet to finish setup is skipped: its start runs the macOS
    /// install or the Linux image download, neither of which may begin
    /// unattended. ``VMConfiguration/hasPendingSetup`` is what decides that, not
    /// the status — ``VMCommandCore/start(_:recovery:)`` dispatches on the
    /// surviving install context too, so a failed install sitting at `.error`
    /// still routes into the installer, and `.error` otherwise means "retry the
    /// boot".
    nonisolated static func autoStartStep(
        startsAutomaticallyOnLaunch: Bool,
        isPreparing: Bool,
        hasPendingSetup: Bool,
        isColdPaused: Bool,
        status: VMStatus
    ) -> AutoStartStep {
        guard startsAutomaticallyOnLaunch, !isPreparing, !hasPendingSetup,
            status != .initialBoot
        else { return .skip }
        if isColdPaused { return .resume }
        return status.canStart ? .start : .skip
    }

    /// Starts every VM marked to start automatically, one after another.
    ///
    /// Sequential on purpose: each guest commits its whole memory allocation at
    /// start, and the duplicate machine-ID and MAC refusals inside the start and
    /// resume verbs compare against VMs that are already live, so they only
    /// answer deterministically once the previous VM has settled.
    ///
    /// Per-VM failures are logged and surfaced by those two methods; the pass
    /// carries on to the next VM either way.
    ///
    /// Cancelling stops it between VMs — a start already inside VZ is left to
    /// finish, since abandoning one mid-flight is worse than completing it.
    func startAutomaticVMsForLaunch() async {
        let marked = instances.filter { $0.configuration.startsAutomaticallyOnLaunch }
        guard !marked.isEmpty else {
            Self.logger.debug("Launch auto-start: no VMs are marked to start automatically")
            return
        }

        Self.logger.notice("Launch auto-start: \(marked.count, privacy: .public) VM(s) marked")

        var startedCount = 0
        var skippedCount = 0
        var failedCount = 0
        for instance in marked {
            // A quit cancels the pass; anything left is the terminating app's
            // business, not this one's.
            if Task.isCancelled {
                Self.logger.notice("Launch auto-start cancelled — the app is terminating")
                break
            }
            // A boot takes long enough for the user to delete or evict a later
            // VM meanwhile, and `marked` still holds that instance. Starting it
            // would open a display window over a bundle no longer in the library.
            guard instances.contains(where: { $0 === instance }) else {
                Self.logger.debug(
                    "Launch auto-start: '\(instance.name, privacy: .public)' left the library before its turn"
                )
                skippedCount += 1
                continue
            }
            // Re-read at the moment of acting rather than trusting the snapshot:
            // the user can start a VM by hand while this pass runs, and the
            // previous iteration's boot is what can make the next one a
            // duplicate-identity conflict.
            let step = Self.autoStartStep(
                startsAutomaticallyOnLaunch: instance.configuration.startsAutomaticallyOnLaunch,
                isPreparing: instance.isPreparing,
                hasPendingSetup: instance.configuration.hasPendingSetup,
                isColdPaused: instance.isColdPaused,
                status: instance.status)
            switch step {
            case .start:
                await start(instance)
            case .resume:
                await resume(instance)
            case .skip:
                Self.logger.debug(
                    "Launch auto-start: skipped '\(instance.name, privacy: .public)' (\(instance.status.displayName, privacy: .public))"
                )
                skippedCount += 1
                continue
            }
            if instance.status.isActive {
                startedCount += 1
            } else {
                failedCount += 1
            }
        }

        Self.logger.notice(
            "Launch auto-start finished — \(startedCount, privacy: .public) running, \(failedCount, privacy: .public) failed, \(skippedCount, privacy: .public) skipped"
        )
    }

    // MARK: - Error Handling

    /// Runs one verb, routing whatever it refuses with to the right surface.
    private func run(on instance: VMInstance?, _ verb: () async throws -> Void) async {
        do {
            try await verb()
        } catch {
            present(error, for: instance)
        }
    }

    /// The synchronous counterpart of ``run(on:_:)``.
    private func runSync(on instance: VMInstance?, _ verb: () throws -> Void) {
        do {
            try verb()
        } catch {
            present(error, for: instance)
        }
    }

    /// The single place a ``CommandError`` becomes something on screen.
    ///
    /// A consent refusal opens the sheet that gathers it; a failure carrying a
    /// recovery opens the alert that offers it; everything else is an error
    /// alert headed by the refusal's own title.
    private func present(_ error: Error, for instance: VMInstance?) {
        guard let command = error as? CommandError else {
            surfaceError(error.localizedDescription)
            return
        }
        switch command {
        case .confirmationRequired(let prompt):
            presentConfirmation(prompt, for: instance)
        case .operationFailed(_, _, let message, let recovery):
            if case .removeStartFailedAttachment(let failure) = recovery, let presenter,
                let instance
            {
                presenter.presentStartFailedAttachment(failure, for: instance)
            } else {
                surfaceError(message, title: command.alertTitle)
            }
        default:
            surfaceError(command.message, title: command.alertTitle)
        }
    }

    /// Opens the sheet that gathers the consent a refusal is asking for.
    ///
    /// Two refusals reach here, both raised by a Stop the user asked for that
    /// only the core can tell is destructive: a live-paused guest that cannot
    /// receive the request, and a cold-paused Ephemeral VM whose stop discards
    /// its suspended session. Every other confirmation is raised by the
    /// `request…` method that opens its own sheet and knows the arguments —
    /// which VM, which snapshot, Trash or immediate — that the prompt alone
    /// does not carry.
    private func presentConfirmation(_ prompt: ConfirmationPrompt, for instance: VMInstance?) {
        guard let instance else { return }
        switch prompt.kind {
        case .stopPaused:
            presenter?.presentStopPaused(for: instance)
        case .forceStop:
            presenter?.presentForceStop(for: instance)
        default:
            Self.logger.debug(
                "No sheet to raise for an unconsented \(prompt.kind.rawValue, privacy: .public)"
            )
        }
    }

    func presentError(_ error: Error) {
        surfaceError(error.localizedDescription)
    }

    /// Routes an error message to the presenter, buffering it if none is
    /// attached yet.
    private func surfaceError(_ message: String, title: String = "Error") {
        if let presenter {
            presenter.presentError(message, title: title)
        } else {
            bufferedErrors.append((title: title, message: message))
        }
    }
}
