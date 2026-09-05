import Foundation
import KernovaKit
import Virtualization
import os

/// The AppKit adapter over ``VMCommanding``: the sheets and alerts that gather
/// consent for a verb, the routing of a refused verb to the right surface, and
/// the inline-rename editing state.
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
    let commands: any VMCommanding

    let storageService: any VMStorageProviding
    let diskImageService: any DiskImageProviding
    let snapshotStore: any VMSnapshotStoring
    let lifecycle: VMLifecycleCoordinator

    /// Pauses running VMs for system sleep and resumes them on wake.
    ///
    /// Held rather than read: the sleep watcher it installs is what drives it,
    /// and this is the composition root that owns its lifetime.
    private let sleepWake: VMSleepWakeCoordinator

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

    var hasUninterruptibleWork: Bool { library.hasUninterruptibleWork }

    var hasSaveInFlight: Bool { library.hasSaveInFlight }

    var hasRevertInFlight: Bool { library.hasRevertInFlight }

    func isBusy(_ instance: VMInstance) -> Bool { library.isBusy(instance) }

    func hasCloneInFlight(from instance: VMInstance) -> Bool {
        library.hasCloneInFlight(from: instance)
    }

    func startLibrary() async { await library.startLibrary() }

    func loadVMs() async { await library.loadVMs() }

    func reconcileWithDisk() { library.reconcileWithDisk() }

    func cancelAndCleanupPreparing() { library.cancelAndCleanupPreparing() }

    func moveVM(fromOffsets source: IndexSet, toOffset destination: Int) {
        library.moveVM(fromOffsets: source, toOffset: destination)
    }

    func waitForRevertsToSettle() async { await library.waitForRevertsToSettle() }

    func vmNamesSharingMACAddress(with instance: VMInstance) -> [String] {
        library.networkSlots.vmNamesSharingMACAddress(with: instance)
    }

    func reservedAddress(for config: VMConfiguration) -> GuestIPAddress {
        library.networkSlots.reservedAddress(for: config)
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
    // documented on ``VMCommanding``.
    //
    // A read that resolves its VM refuses only with
    // ``CommandError/notFound(_:)``, which a sheet still up while its VM left
    // the library is the one way to reach: there is nothing for a user to act
    // on, so it reads as empty and is logged.

    /// Every per-VM capability predicate the AppKit surfaces read.
    var capabilities: VMCapabilityCatalog { library.capabilities }

    func canDeleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) -> Bool {
        capabilities.canDeleteSnapshot(snapshot, on: instance)
    }

    func snapshotOnDiskBytes(for instance: VMInstance) async -> [UUID: UInt64] {
        do {
            return try await commands.snapshotOnDiskBytes(of: .id(instance.id))
        } catch {
            Self.logger.debug(
                "No snapshot sizes for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    func externalAttachments(for instance: VMInstance) async -> [ExternalAttachment] {
        do {
            return try await commands.externalAttachments(of: .id(instance.id))
        } catch {
            Self.logger.debug(
                "No external attachments for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    func sharingVMNames(
        forPath path: String, bookmark: Data?, excluding instance: VMInstance
    ) async -> [String] {
        do {
            return try await commands.sharingVMNames(
                .id(instance.id), path: path, bookmark: bookmark)
        } catch {
            Self.logger.debug(
                "No sharing names for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    // MARK: - Attachment Forwarding

    // The settings pane's Storage and Sharing categories, one forward per
    // verb, each documented on ``VMCommanding``. The pane gathers the consent
    // a trashing removal asks for, so the storage and removable-media removals
    // arrive pre-confirmed; a share removal destroys nothing and asks none.

    func attachStorageDisks(_ files: [PickedFile], to instance: VMInstance) {
        runEdit(on: instance) { try self.commands.attachStorageDisks(.id(instance.id), paths: files) }
    }

    func createStorageDisk(for instance: VMInstance, sizeInGB: Int) async {
        await run(on: instance) {
            try await self.commands.createStorageDisk(.id(instance.id), sizeInGB: sizeInGB)
        }
    }

    func removeStorageDisk(_ disk: UUID, from instance: VMInstance, trashFile: Bool) async {
        await runEdit(on: instance) {
            try await self.commands.removeStorageDisk(
                .id(instance.id), disk: disk, trashFile: trashFile, confirmed: true)
        }
    }

    func renameStorageDisk(_ disk: UUID, newLabel: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.renameStorageDisk(.id(instance.id), disk: disk, to: newLabel)
        }
    }

    func setStorageDiskNotes(_ disk: UUID, notes: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setStorageDiskNotes(.id(instance.id), disk: disk, notes: notes)
        }
    }

    func setStorageDiskReadOnly(_ disk: UUID, readOnly: Bool, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setStorageDiskReadOnly(
                .id(instance.id), disk: disk, readOnly: readOnly)
        }
    }

    func reorderStorageDisks(_ order: [UUID], on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.reorderStorageDisks(.id(instance.id), order: order)
        }
    }

    func attachRemovableMedia(_ files: [PickedFile], to instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.attachRemovableMedia(.id(instance.id), paths: files)
        }
    }

    func createRemovableMedia(
        for instance: VMInstance, sizeInGB: Int, destinationURL: URL
    ) async {
        await run(on: instance) {
            try await self.commands.createRemovableMedia(
                .id(instance.id), sizeInGB: sizeInGB, destinationURL: destinationURL)
        }
    }

    func removeRemovableMedia(_ item: UUID, from instance: VMInstance, trashFile: Bool) async {
        await runEdit(on: instance) {
            try await self.commands.removeRemovableMedia(
                .id(instance.id), item: item, trashFile: trashFile, confirmed: true)
        }
    }

    func ejectRemovableMedia(_ item: UUID, from instance: VMInstance) {
        runEdit(on: instance) { try self.commands.ejectRemovableMedia(.id(instance.id), item: item) }
    }

    func renameRemovableMedia(_ item: UUID, newLabel: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.renameRemovableMedia(.id(instance.id), item: item, to: newLabel)
        }
    }

    func setRemovableMediaNotes(_ item: UUID, notes: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setRemovableMediaNotes(.id(instance.id), item: item, notes: notes)
        }
    }

    func setRemovableMediaReadOnly(_ item: UUID, readOnly: Bool, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setRemovableMediaReadOnly(
                .id(instance.id), item: item, readOnly: readOnly)
        }
    }

    func addSharedDirectories(_ files: [PickedFile], to instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.addSharedDirectories(.id(instance.id), paths: files)
        }
    }

    func removeSharedDirectory(_ directory: UUID, from instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.removeSharedDirectory(.id(instance.id), directory: directory)
        }
    }

    func setSharedDirectoryReadOnly(_ directory: UUID, readOnly: Bool, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setSharedDirectoryReadOnly(
                .id(instance.id), directory: directory, readOnly: readOnly)
        }
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
            guard presenter != nil else { return }
            if !bufferedErrors.isEmpty {
                let buffered = bufferedErrors
                bufferedErrors.removeAll()
                buffered.forEach { presenter?.presentError($0.message, title: $0.title) }
            }
            if let id = bufferedDisplayFocus {
                bufferedDisplayFocus = nil
                if let instance = instances.first(where: { $0.id == id }) {
                    presenter?.focusGuestDisplay(for: instance)
                }
            }
        }
    }

    @ObservationIgnored private var bufferedErrors: [(title: String, message: String)] = []

    /// The VM an inline surface was asked for before any window existed, focused
    /// when the presenter attaches — the same buffering `bufferedErrors` does,
    /// for the same reason.
    @ObservationIgnored private var bufferedDisplayFocus: UUID?

    var activeRename: RenameTarget?

    /// Called when a VM with a non-inline `displayPreference` is about to start or resume,
    /// allowing the app delegate to pre-create the display window with a spinner.
    @ObservationIgnored var onOpenDisplayWindow: ((VMInstance) -> Void)?

    /// Asks for the library window, for an inline surface with nowhere to land.
    ///
    /// The inline display lives inside the main window, so a verb surfacing one
    /// on a process that has never opened a window — an intent on the headless
    /// launch path — has to bring that window up first or do nothing at all.
    @ObservationIgnored var onSurfaceLibrary: (() -> Void)?

    /// Measures the window or screen a starting VM's display will occupy, for
    /// `displaySizesToWindow`.
    @ObservationIgnored weak var displayBootGeometryProvider: (any DisplayBootGeometryProviding)?

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
        vmnetNetworks: any VmnetNetworkProviding & VmnetNetworkRecreating = VmnetNetworkService.shared,
        isVMNetworkingEntitled: Bool = EntitlementService.shared.hasVMNetworking
    ) {
        self.storageService = storageService
        self.diskImageService = diskImageService
        self.snapshotStore = snapshotStore
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
        let sleepWake = VMSleepWakeCoordinator(lifecycle: lifecycle, roster: library)
        self.sleepWake = sleepWake
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storageService,
            snapshotStore: snapshotStore,
            diskImageService: diskImageService,
            fileSystem: fileSystem,
            preferences: preferences
        )
        self.commands = core

        library.onFailure = { [weak self] title, message in
            self?.surfaceError(message, title: title)
        }
        sleepWake.onFailure = { [weak self] error in
            self?.surfaceError(error.localizedDescription)
        }
        // The same routing a call site gets, so a failure nobody awaited still
        // reaches the sheet or the recovery alert its type asks for.
        core.onFailure = { [weak self] failure, instance in
            self?.present(failure, for: instance)
        }
        core.surfaceDisplay = { [weak self] instance in
            self?.surfaceDisplay(for: instance)
        }
        // Through this adapter rather than handed over, so the core retains
        // neither the view model nor the app delegate behind it.
        core.displayBootSurface = { [weak self] instance in
            self?.displayBootGeometryProvider?.displayBootSurface(for: instance)
        }
    }

    // MARK: - Create

    /// Registers the row a wizard's VM will fill and spawns the bundle write,
    /// optionally auto-starting the VM once it lands.
    ///
    /// The pre-write refusal is thrown rather than presented so the wizard host
    /// can show it on the wizard's own sheet and keep it open for a retry — two
    /// sheets on one window contend, and the sheet is still up at this point. A
    /// failure of the write itself arrives after the sheet is gone, and reaches
    /// the user through ``VMCommandCore/onFailure``.
    func createVM(from wizard: VMCreationViewModel) throws {
        try commands.create(
            configuration: wizard.buildConfiguration(),
            startAfterCreate: wizard.startAfterCreate)
    }

    // MARK: - Lifecycle

    /// Surfaces the display a start/resume lands on: the detached window for
    /// pop-out/fullscreen VMs, else keyboard focus in the inline guest display.
    private func surfaceDisplay(for instance: VMInstance) {
        if instance.configuration.displayPreference != .inline {
            onOpenDisplayWindow?(instance)
        } else {
            // The inline display renders whichever VM is selected, so selecting
            // is what surfacing *is* here — `focusGuestDisplay` on an unselected
            // VM only arms a focus that the next display-state pass clears.
            // Detached windows are their own surface and need no selection.
            selectedID = instance.id
            guard let presenter else {
                // No window has ever been created, so there is no inline display
                // to focus yet. Ask for one and focus when it attaches.
                bufferedDisplayFocus = instance.id
                onSurfaceLibrary?()
                return
            }
            presenter.focusGuestDisplay(for: instance)
        }
    }

    func start(
        _ instance: VMInstance, bootIntoRecovery: Bool = false,
        presentation: VMDisplayPresentation = .surface
    ) async {
        await run(on: instance) {
            try await self.commands.start(
                .id(instance.id), recovery: bootIntoRecovery, presentation: presentation)
        }
    }

    /// Confirmed action of the start-failed alert, performed by the core that
    /// offered the recovery.
    func removeStartFailedAttachmentAndStart(
        _ failure: StartFailedAttachment, on instance: VMInstance
    ) async {
        await commands.removeStartFailedAttachmentAndStart(.id(instance.id), attachment: failure)
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

    func resume(
        _ instance: VMInstance, presentation: VMDisplayPresentation = .surface
    ) async {
        await run(on: instance) {
            try await self.commands.resume(.id(instance.id), presentation: presentation)
        }
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
        guard capabilities.isAvailable(.takeSnapshot, on: instance) else { return }
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
        guard capabilities.isAvailable(.revertToSnapshot, on: instance) else { return }
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
    /// Test-only seam awaiting every in-flight preparing (create/clone/import) task.
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

    /// Opens the cancel-create/clone/import confirmation.
    func requestCancelPreparing(_ instance: VMInstance) {
        presenter?.presentCancelPreparing(for: instance)
    }

    /// Cancels an in-flight create, clone or import from that confirmation's confirm.
    func cancelPreparing(_ instance: VMInstance) {
        do {
            try commands.cancelPreparing(.id(instance.id), confirmed: true)
        } catch let error as CommandError {
            // The row went while the confirmation was up — a settled copy is
            // cleaned up rather than refused, so what reaches here is a VM that
            // is no longer in the library, or one that is no longer at rest.
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

    /// Mounts the bundled `KernovaMacOSAgent.dmg` so the user can run
    /// `install.command` inside the guest, then shows the next-step alert.
    ///
    /// The alert is the whole action on two of the verb's three paths — an
    /// image already mounted, and a guest that takes it on virtio for the whole
    /// session — so every outcome presents it.
    func mountGuestAgentInstaller(
        on instance: VMInstance, purpose: GuestAgentInstallerPurpose = .install
    ) {
        runEdit(on: instance) {
            let outcome = try self.commands.mountGuestAgentDisk(.id(instance.id))
            self.presenter?.presentInstallerMounted(
                vmName: instance.name, purpose: purpose, delivery: outcome.delivery)
        }
    }

    /// Removes the bundled guest agent installer entry from `removableMedia` if
    /// currently present. The reconcile flow performs the runtime detach.
    func unmountGuestAgentInstaller(from instance: VMInstance) {
        runEdit(on: instance) { try self.commands.unmountGuestAgentDisk(.id(instance.id)) }
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

    // MARK: - Launch Auto-Start

    /// Names of the macOS VMs marked to start automatically, in library order —
    /// which is the order ``startAutomaticVMsForLaunch(surfacingDisplays:)``
    /// reaches them in.
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
    /// the phase — ``VMCommandCore/start(_:recovery:)`` dispatches on the
    /// surviving install context too, so a failed install sitting at `.failed`
    /// still routes into the installer, and `.failed` otherwise means "retry the
    /// boot".
    nonisolated static func autoStartStep(
        startsAutomaticallyOnLaunch: Bool,
        isPreparing: Bool,
        hasPendingSetup: Bool,
        phase: VMLifecyclePhase
    ) -> AutoStartStep {
        guard startsAutomaticallyOnLaunch, !isPreparing, !hasPendingSetup,
            phase != .initialBoot
        else { return .skip }
        if phase.isColdPaused { return .resume }
        return phase.canStart ? .start : .skip
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
    ///
    /// `surfacingDisplays` is `false` for a launch that came up headless: a
    /// login launch boots its marked VMs with no window, and surfacing one would
    /// give the process the library window and Dock icon it was asked not to
    /// have.
    func startAutomaticVMsForLaunch(surfacingDisplays: Bool) async {
        let presentation: VMDisplayPresentation = surfacingDisplays ? .surface : .headless
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
                phase: instance.phase)
            switch step {
            case .start:
                await start(instance, presentation: presentation)
            case .resume:
                await resume(instance, presentation: presentation)
            case .skip:
                Self.logger.debug(
                    "Launch auto-start: skipped '\(instance.name, privacy: .public)' (\(instance.status.displayName, privacy: .public))"
                )
                skippedCount += 1
                continue
            }
            if instance.isActive {
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

    /// Runs one attachment edit, routing refusals as ``runSync(on:_:)`` does
    /// but logging the failure a race raises instead of alerting on it.
    ///
    /// Two things reach here as
    /// ``CommandError/operationFailed(verb:title:message:recovery:)``: an edit
    /// naming an attachment the list no longer carries — a rename field
    /// committing after its row went, a second alert for a disk the first
    /// already removed — and a configuration write the funnel has already told
    /// the user about. Both were silent before there was a verb to refuse them,
    /// and the verb throws so a wire client hears about it.
    private func runEdit(on instance: VMInstance, _ verb: () throws -> Void) {
        do {
            try verb()
        } catch let error as CommandError where error.isOperationFailure {
            Self.logger.debug(
                "Attachment edit on '\(instance.name, privacy: .public)' did not apply: \(error.message, privacy: .public)"
            )
        } catch {
            present(error, for: instance)
        }
    }

    /// The asynchronous counterpart of ``runEdit(on:_:)``.
    private func runEdit(on instance: VMInstance, _ verb: () async throws -> Void) async {
        do {
            try await verb()
        } catch let error as CommandError where error.isOperationFailure {
            Self.logger.debug(
                "Attachment edit on '\(instance.name, privacy: .public)' did not apply: \(error.message, privacy: .public)"
            )
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
