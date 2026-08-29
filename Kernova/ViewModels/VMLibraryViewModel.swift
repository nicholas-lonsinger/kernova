import Foundation
import Virtualization
import os

/// The AppKit adapter over ``VMLibrary``: the VM verbs, the sheets and alerts
/// that gather consent for them, and the inline-rename editing state.
///
/// Owns the library, routes its ``VMLibrary/onFailure`` and per-instance hooks
/// to the presenter, and forwards its reads so a view controller holding a view
/// model still sees one surface.
@MainActor
@Observable
final class VMLibraryViewModel {
    nonisolated private static let logger = Logger(subsystem: "app.kernova", category: "VMLibraryViewModel")

    // MARK: - Services

    /// Which VMs exist, and everything that keeps that set in step with disk.
    let library: VMLibrary

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
        self.library = VMLibrary(
            storageService: storageService,
            snapshotStore: snapshotStore,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: vmnetNetworks,
            isVMNetworkingEntitled: isVMNetworkingEntitled
        )

        library.onFailure = { [weak self] title, message in
            self?.surfaceError(message, title: title)
        }
        library.onAgentBecameCurrent = { [weak self] instance in
            self?.unmountGuestAgentInstaller(from: instance)
        }
        library.onPoweredOff = { [weak self] instance in
            self?.revertToEphemeralBaselineIfNeeded(instance)
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

    // MARK: - Guest Setup

    /// Runs a guest-setup pipeline for an `.initialBoot` (or `.error` with a
    /// surviving context) VM and, on success, chains an auto-boot.
    ///
    /// A permanent failure leaves the VM in `.error` so the banner keeps the
    /// message on screen; cancel and transient failures (the running-VM cap)
    /// return it to `.initialBoot` for a retry that resumes the download from
    /// the `.kernovadownload` bundle if present.
    private func runGuestSetup(
        on instance: VMInstance,
        _ pipeline: @escaping (VMLifecycleCoordinator) async throws -> Void
    ) {
        if instance.setupTask != nil { return }  // guard against rapid double-click
        instance.setupTask = Task { [weak self] in
            guard let self else { return }
            defer { instance.setupTask = nil }
            do {
                try await pipeline(self.lifecycle)
                instance.setupState = nil
                await self.start(instance)
            } catch is CancellationError {
                // Tear down a VM the install attached before cancellation fired: a
                // retry would otherwise build a fresh `VZMacAuxiliaryStorage` while
                // the old one is still alive on `instance.session`.
                instance.tearDownSession()
                instance.setupState = nil
                instance.errorMessage = nil
                instance.status = .initialBoot
                Self.logger.notice(
                    "Setup cancelled for '\(instance.name, privacy: .public)' — VM remains in .initialBoot"
                )
            } catch {
                // Same teardown reason as the cancel branch: an attached VM from a
                // partial install must not bleed into the next retry.
                instance.tearDownSession()
                instance.setupState = nil
                if Task.isCancelled {
                    // A non-cancellation error arrived before the cancel propagated
                    // (e.g. a network failure raced it). User intent was cancel, so
                    // route back to `.initialBoot` and drop the message — no dialog.
                    instance.errorMessage = nil
                    instance.status = .initialBoot
                    Self.logger.notice(
                        "Setup cancelled for '\(instance.name, privacy: .public)' — pipeline surfaced \(error.localizedDescription, privacy: .public)"
                    )
                } else if let explained = self.explainedFailure(for: error, on: instance) {
                    self.surfaceError(explained.message, title: explained.title)
                } else {
                    self.presentError(error)
                }
            }
        }
    }

    /// Drives the macOS install pipeline for a VM carrying an `installContext`.
    private func installAndAutoBoot(_ instance: VMInstance) {
        guard let context = instance.configuration.installContext else {
            assertionFailure("installAndAutoBoot called without installContext")
            return
        }
        runGuestSetup(on: instance) { lifecycle in
            try await lifecycle.installMacOS(on: instance, context: context)
        }
    }

    /// Drives the Linux installer-image pipeline for a VM carrying a
    /// `linuxInstallContext`.
    private func downloadAndAutoBoot(_ instance: VMInstance) {
        guard let context = instance.configuration.linuxInstallContext else {
            assertionFailure("downloadAndAutoBoot called without linuxInstallContext")
            return
        }
        runGuestSetup(on: instance) { lifecycle in
            try await lifecycle.downloadLinuxImage(on: instance, context: context)
        }
    }

    /// Cancels the in-progress guest setup — a macOS install, or a Linux
    /// installer image being fetched or verified.
    ///
    /// The VM returns to `.initialBoot` so a subsequent Start can resume, and the
    /// bundle is preserved — this is the non-destructive cancel.
    func cancelGuestSetup(_ instance: VMInstance) {
        Self.logger.info("Cancelling setup for '\(instance.name, privacy: .public)'")
        instance.setupTask?.cancel()
        // `runGuestSetup`'s cancel catch owns the status transition and
        // `setupState` cleanup — don't duplicate it here.
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
        // Ahead of the setup dispatch: guest setup builds and runs a
        // `VZVirtualMachine` carrying the configured machine identity and MAC
        // address, so a conflicting one must be refused before it reaches the
        // installer, not only on the auto-boot that follows.
        if refuseIfDuplicateMachineIDConflict(instance) { return }
        if library.refuseIfDuplicateMACAddressConflict(instance, joining: instance.configuration) { return }

        // Dispatch on the surviving setup context, not status, so `.error`
        // retries route through the same pipeline too.
        if instance.configuration.installContext != nil {
            installAndAutoBoot(instance)
            return
        }
        if instance.configuration.linuxInstallContext != nil {
            downloadAndAutoBoot(instance)
            return
        }

        surfaceDisplay(for: instance)
        applyMatchWindowBootResolution(to: instance)
        do {
            try await lifecycle.start(instance, bootIntoRecovery: bootIntoRecovery)
        } catch {
            Self.logger.error(
                "Failed to start '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            if let presenter, let failure = startFailedAttachment(from: error, on: instance) {
                presenter.presentStartFailedAttachment(failure, for: instance)
            } else if let explained = explainedFailure(for: error, on: instance) {
                surfaceError(explained.message, title: explained.title)
            } else {
                presentError(error)
            }
        }
    }

    /// Refuses an operation that would claim a machine identity another VM
    /// already holds, logging the refusal and surfacing the alert.
    ///
    /// - Returns: `true` when the caller must abort.
    private func refuseIfDuplicateMachineIDConflict(_ instance: VMInstance) -> Bool {
        guard preferences.blockDuplicateMachineIDBoot,
            let conflict = liveMachineIDConflict(for: instance)
        else { return false }
        Self.logger.notice(
            "Refused to run '\(instance.name, privacy: .public)': shares a machine ID with active VM '\(conflict.name, privacy: .public)'"
        )
        surfaceError(
            "“\(instance.name)” has the same machine ID as “\(conflict.name)”, which is active. "
                + "Two virtual machines with the same machine ID must not run at once. "
                + "Stop “\(conflict.name)” first, or allow this in Settings → Advanced.",
            title: "Duplicate Machine ID")
        return true
    }

    /// The first VM holding a live machine identity matching the given
    /// instance's, if any.
    ///
    /// Live means VZ holds the identity: any active status, or paused with the
    /// virtual machine still in memory. A cold-paused VM has released it, and
    /// blocking its twin on a saved state that claims nothing would be wrong.
    private func liveMachineIDConflict(for instance: VMInstance) -> VMInstance? {
        instances.first { other in
            other !== instance
                && (other.status.isActive || other.isLivePaused)
                && Self.sharesMachineIdentifier(instance, other)
        }
    }

    /// Whether two VMs would claim the same machine identity.
    ///
    /// macOS identifiers compare the *effective* value, which falls back to the
    /// bundle's identifier file exactly as the boot path does; generic
    /// identifiers have no such file, so they compare configuration fields.
    private static func sharesMachineIdentifier(_ a: VMInstance, _ b: VMInstance) -> Bool {
        if let lhs = a.effectiveMachineIdentifierData, let rhs = b.effectiveMachineIdentifierData,
            lhs == rhs
        {
            return true
        }
        if let lhs = a.configuration.genericMachineIdentifierData,
            let rhs = b.configuration.genericMachineIdentifierData,
            lhs == rhs
        {
            return true
        }
        return false
    }

    /// Resizes a cold-booting VM's display to the surface it is about to appear
    /// on, persisting the result before the VZ configuration is built.
    ///
    /// Left alone when a save file exists: VZ restores only into a configuration
    /// identical to the saved one, and a mismatch fails the restore.
    private func applyMatchWindowBootResolution(to instance: VMInstance) {
        guard instance.configuration.displaySizesToWindow, !instance.hasSaveFile else { return }
        guard let surface = displayBootGeometryProvider?.displayBootSurface(for: instance) else {
            Self.logger.notice(
                "No measurable display surface for '\(instance.name, privacy: .public)' — booting at the configured resolution"
            )
            return
        }
        let hiDPI =
            instance.configuration.guestOS.supportsDisplayDensity
            && instance.configuration.displayHiDPI
        let scale = hiDPI ? surface.backingScaleFactor : 1
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: surface.pointSize, backingScaleFactor: scale)
        let previous = instance.configuration
        if !updateConfiguration(of: instance, mutate: { $0.displayResolution = resolution }) {
            // Assigned directly rather than through the funnel: disk still holds
            // `previous`, so re-persisting it is a second chance to fail.
            instance.configuration = previous
            Self.logger.warning(
                "Could not persist the window-fitted resolution for '\(instance.name, privacy: .public)' — booting at the previously saved resolution"
            )
        }
    }

    /// The storage disk `id` refers to, resolving the synthesized main disk
    /// when the VM has no explicit list.
    private func storageDisk(id: UUID, on instance: VMInstance) -> StorageDisk? {
        (instance.configuration.storageDisks ?? Self.defaultStorageDisks(for: instance))
            .first { $0.id == id }
    }

    /// Maps a start error to a ``StartFailedAttachment`` when it identifies an
    /// attachment the user can remove to get the VM running, or `nil` when the
    /// generic error alert is the right surface.
    ///
    /// Two exclusions where removal is the wrong advice: the disk the guest boots
    /// from, and file-lock contention — the file is fine and the lock holder is a VM
    /// still tearing down, so the fix is to wait and retry.
    private func startFailedAttachment(
        from error: Error, on instance: VMInstance
    ) -> StartFailedAttachment? {
        guard let builderError = error as? ConfigurationBuilderError,
            !VirtualizationService.isFileLockContention(builderError)
        else { return nil }
        switch builderError {
        case .storageDiskAttachFailed(let id, _, let label, _):
            guard let disk = storageDisk(id: id, on: instance),
                !isMainDisk(disk, of: instance)
            else { return nil }
            return StartFailedAttachment(
                kind: .storageDisk, id: id, label: label,
                message: builderError.localizedDescription)
        case .removableMediaAttachFailed(let id, _, let label, _):
            // Confirm the entry is really in the list: an offer whose action could
            // only no-op leaves a button that appears to do nothing.
            guard (instance.configuration.removableMedia ?? []).contains(where: { $0.id == id })
            else { return nil }
            return StartFailedAttachment(
                kind: .removableMedia, id: id, label: label,
                message: builderError.localizedDescription)
        default:
            return nil
        }
    }

    /// Maps a start or install failure to alert copy naming the cause and the
    /// remedy, or `nil` when the raw error description is the right surface.
    private func explainedFailure(
        for error: Error, on instance: VMInstance
    ) -> (title: String, message: String)? {
        guard VirtualizationService.isVirtualMachineLimitExceeded(error) else { return nil }
        let verb: String
        switch instance.startAction {
        case .start: verb = "Start"
        case .install, .resumeInstall: verb = "Install"
        case .download, .resumeDownload: verb = "Download"
        }
        let message: String
        switch instance.configuration.guestOS {
        case .macOS:
            message =
                "macOS allows at most two macOS virtual machines to run at once. Stop another macOS VM, then click \(instance.startAction.label) to try again."
        case .linux:
            message =
                "The limit on running virtual machines has been reached. Stop another virtual machine, then click \(instance.startAction.label) to try again."
        }
        return (title: "Couldn't \(verb) “\(instance.name)”", message: message)
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
            if let disk = storageDisk(id: failure.id, on: instance) {
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
        // VZ rejects requestStop() on paused VMs ("Invalid virtual machine state").
        // Surface a confirmation sheet offering resume-and-shutdown or force-stop instead.
        if instance.isLivePaused {
            presenter?.presentStopPaused(for: instance)
            return
        }
        if await discardedSavedStateAsEphemeralRevert(instance) { return }
        do {
            try await lifecycle.stop(instance)
        } catch {
            Self.logger.error(
                "Failed to stop '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    /// Resumes a paused VM then requests a graceful ACPI shutdown.
    func resumeAndStop(_ instance: VMInstance) async {
        do {
            try await lifecycle.resume(instance)
            try await lifecycle.stop(instance)
        } catch {
            Self.logger.error(
                "Failed to resume-and-stop '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
        }
    }

    /// Force-stops a paused VM via the stop-paused confirmation sheet's "Force Stop" action.
    func forceStopFromPaused(_ instance: VMInstance) async {
        await forceStop(instance)
    }

    func forceStop(_ instance: VMInstance) async {
        if await discardedSavedStateAsEphemeralRevert(instance) { return }
        do {
            try await lifecycle.forceStop(instance)
            Self.logger.notice("Force-stopped VM '\(instance.name, privacy: .public)'")
        } catch {
            Self.logger.error(
                "Failed to force-stop '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
        }
    }

    // MARK: - Force Stop Confirmation

    func confirmForceStop(_ instance: VMInstance) {
        presenter?.presentForceStop(for: instance)
    }

    func forceStopConfirmed(_ instance: VMInstance) async {
        await forceStop(instance)
    }

    // MARK: - Recovery Boot

    /// Presents the confirmation alert for booting a stopped macOS guest into
    /// macOS Recovery.
    func confirmStartInRecovery(_ instance: VMInstance) {
        presenter?.presentRecoveryBoot(for: instance)
    }

    /// Invoked from the recovery-boot confirmation alert's confirm button.
    func startInRecoveryConfirmed(_ instance: VMInstance) async {
        await start(instance, bootIntoRecovery: true)
    }

    func pause(_ instance: VMInstance) async {
        do {
            try await lifecycle.pause(instance)
        } catch {
            Self.logger.error(
                "Failed to pause '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    func resume(_ instance: VMInstance) async {
        // A cold resume builds a fresh VZVirtualMachine from the save file, so it
        // claims the machine identity — and puts its MAC address back on a
        // network — just as a cold boot does. A hot resume's live object already
        // holds both, and refusing would be refusing a VM its own identity.
        if instance.isColdPaused {
            if refuseIfDuplicateMachineIDConflict(instance) { return }
            if library.refuseIfDuplicateMACAddressConflict(instance, joining: instance.configuration) {
                return
            }
        }

        surfaceDisplay(for: instance)
        do {
            try await lifecycle.resume(instance)
        } catch {
            Self.logger.error(
                "Failed to resume '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
        }
    }

    func save(_ instance: VMInstance) async {
        do {
            try await lifecycle.save(instance)
        } catch {
            Self.logger.error(
                "Failed to save '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    /// Saves VM state, throwing on failure (used by suspend-on-quit in AppDelegate).
    func trySave(_ instance: VMInstance) async throws {
        try await lifecycle.save(instance)
    }

    /// Force-stops a VM, throwing on failure (used by suspend-on-quit fallback in AppDelegate).
    func tryForceStop(_ instance: VMInstance) async throws {
        try await lifecycle.forceStop(instance)
    }

    // MARK: - Snapshots

    /// Re-reads a bundle's snapshot manifest into its instance.
    ///
    /// Every instance is seeded at construction; this is for the paths that put
    /// files in the bundle afterwards (an import copying a bundle that already
    /// carries snapshots).
    func reloadSnapshots(for instance: VMInstance) {
        instance.snapshotManifest = snapshotStore.loadManifest(bundleURL: instance.bundleURL)
    }

    /// Whether Take Snapshot is offered right now — the single gate every
    /// surface enables its command from.
    ///
    /// ``VMInstance/canTakeSnapshot`` alone answers the VM's state; an
    /// operation still settling would reject the capture, so it has to be part
    /// of the same read or the command reads as available and errors instead.
    func canTakeSnapshot(_ instance: VMInstance) -> Bool {
        instance.canTakeSnapshot && !isBusy(instance)
    }

    /// Whether a revert is offered right now — the counterpart gate to
    /// ``canTakeSnapshot(_:)``.
    func canRevertToSnapshot(_ instance: VMInstance) -> Bool {
        instance.canRevertToSnapshot && !isBusy(instance)
    }

    /// Whether a snapshot may be deleted — the one snapshot-list edit that
    /// goes through the same per-VM serialization a revert holds.
    func canDeleteSnapshots(_ instance: VMInstance) -> Bool {
        !isBusy(instance)
    }

    /// Opens the Take Snapshot sheet.
    func requestTakeSnapshot(_ instance: VMInstance) {
        guard canTakeSnapshot(instance) else { return }
        presenter?.presentTakeSnapshotSheet(for: instance)
    }

    /// Captures a snapshot and lists it in the manifest.
    ///
    /// Re-checks the gate: the sheet gathers a name and notes, so the VM can
    /// move between opening it and confirming.
    ///
    /// The returned Task lets tests await the capture.
    @discardableResult
    func takeSnapshot(_ instance: VMInstance, name: String, notes: String = "") -> Task<Void, Never> {
        guard canTakeSnapshot(instance) else {
            Self.logger.notice(
                "Refusing to snapshot '\(instance.name, privacy: .public)': the VM is no longer in a state to capture"
            )
            return Task {}
        }
        return Task { _ = await captureSnapshot(instance, name: name, notes: notes) }
    }

    /// The capture itself, answering the snapshot that landed — `nil` when
    /// anything failed, so a caller chaining off it (the revert alert's
    /// snapshot-first path) stops rather than proceeding on a lost checkpoint.
    private func captureSnapshot(
        _ instance: VMInstance, name: String, notes: String
    ) async -> VMSnapshot? {
        // Stamped at confirm time, not when the sheet opened: the VM can
        // start, stop, or suspend while it is up.
        guard let mode = instance.snapshotCaptureMode else {
            Self.logger.notice(
                "Refusing to snapshot '\(instance.name, privacy: .public)': the VM is no longer in a state to capture"
            )
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = VMSnapshot(
            name: trimmedName.isEmpty ? instance.snapshotManifest.defaultNewName : trimmedName,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: mode.kind)
        do {
            try await lifecycle.takeSnapshot(
                instance, snapshot: snapshot, store: snapshotStore)
        } catch {
            Self.logger.error(
                "Failed to take a snapshot of '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
            return nil
        }
        var manifest = instance.snapshotManifest
        manifest.insert(snapshot)
        guard writeSnapshotManifest(manifest, for: instance) else {
            // Unlisted files are files no surface can reach or remove, so the
            // capture is undone rather than left orphaned in the bundle.
            let store = snapshotStore
            let bundleURL = instance.bundleURL
            let id = snapshot.id
            await Task.detached {
                store.removeSnapshotDirectory(bundleURL: bundleURL, snapshotID: id)
            }.value
            return nil
        }
        return snapshot
    }

    /// Shows the revert confirmation.
    func confirmRevert(_ instance: VMInstance, to snapshot: VMSnapshot) {
        guard canRevertToSnapshot(instance) else { return }
        presenter?.presentRevertSnapshot(snapshot, for: instance)
    }

    /// Takes a fresh snapshot of the current state, then reverts — the revert
    /// alert's default, non-destructive path.
    ///
    /// The button this backs only exists when the alert was built with a
    /// capturable VM, so the capture here is required, not conditional: a VM
    /// that stopped being capturable before the click landed aborts rather
    /// than falling through to the destructive revert with no check-point.
    func snapshotThenRevertConfirmed(_ instance: VMInstance, to snapshot: VMSnapshot) async {
        guard
            await captureSnapshot(
                instance, name: instance.snapshotManifest.defaultNewName, notes: "") != nil
        else { return }
        await revertConfirmed(instance, to: snapshot)
    }

    func revertConfirmed(_ instance: VMInstance, to snapshot: VMSnapshot) async {
        await startRevert(instance, to: snapshot).value
    }

    /// Registers a revert and runs it.
    ///
    /// Registration happens *before this returns*, not when the copy starts:
    /// the task body runs no earlier than the caller's next suspension, so a
    /// termination gate that reads ``hasRevertInFlight`` immediately after a
    /// power-off sees the revert the power-off requested. Registering from
    /// inside the task instead would leave a window where the revert is pending
    /// and invisible.
    @discardableResult
    private func startRevert(_ instance: VMInstance, to snapshot: VMSnapshot) -> Task<Void, Never> {
        let requestID = UUID()
        let task = Task { [weak self] in
            await self?.performRevert(instance, to: snapshot)
            self?.library.revertTasks[requestID] = nil
        }
        library.revertTasks[requestID] = task
        return task
    }

    private func performRevert(_ instance: VMInstance, to snapshot: VMSnapshot) async {
        guard instance.snapshotManifest.snapshot(id: snapshot.id) != nil else {
            Self.logger.notice(
                "Refusing to revert '\(instance.name, privacy: .public)': the snapshot is no longer listed"
            )
            return
        }
        // A VM that is live goes back to being live once the files are in
        // place, so the window it comes up in is chosen before the teardown. A
        // cold snapshot ends the session for good, so there is none to choose.
        if instance.hasLiveVirtualMachine, snapshot.kind == .warm {
            surfaceDisplay(for: instance)
        }
        do {
            try await lifecycle.revertToSnapshot(
                instance, snapshot: snapshot, store: snapshotStore)
        } catch {
            Self.logger.error(
                "Failed to revert '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
            // A resume that failed left the reverted files in place, so the VM's
            // state does descend from this snapshot and the marker says so.
            guard case VirtualizationError.revertResumeFailed = error else { return }
        }
        var manifest = instance.snapshotManifest
        manifest.currentID = snapshot.id
        writeSnapshotManifest(manifest, for: instance)
    }

    // MARK: - Ephemeral Mode

    /// Returns an Ephemeral Mode VM to its baseline after a power-off; a no-op
    /// for every other VM.
    ///
    /// Reached from ``VMInstance/onPoweredOff``, which fires inside the stop
    /// that caused it — so the revert runs in its own task, after that stop has
    /// released the VM.
    private func revertToEphemeralBaselineIfNeeded(_ instance: VMInstance) {
        guard let baseline = instance.ephemeralBaselineSnapshot else { return }
        revertToEphemeralBaseline(instance, baseline)
    }

    /// The revert an ephemeral power-off performs, on the same path a
    /// user-confirmed revert takes — including its error presentation, so a
    /// baseline that cannot be restored is never silently skipped.
    @discardableResult
    private func revertToEphemeralBaseline(
        _ instance: VMInstance, _ baseline: VMSnapshot
    ) -> Task<Void, Never> {
        Self.logger.notice(
            "Reverting ephemeral VM '\(instance.name, privacy: .public)' to its baseline '\(baseline.name, privacy: .public)'"
        )
        return startRevert(instance, to: baseline)
    }

    /// Routes a cold-paused ephemeral VM's Discard Saved State through the
    /// baseline revert instead, and reports whether it took the request.
    ///
    /// Discarding alone would drop the suspended session and leave the guest's
    /// disks as the session left them — the opposite of what the mode promises.
    private func discardedSavedStateAsEphemeralRevert(_ instance: VMInstance) async -> Bool {
        guard instance.isColdPaused, let baseline = instance.ephemeralBaselineSnapshot else {
            return false
        }
        await revertToEphemeralBaseline(instance, baseline).value
        return true
    }

    /// Whether `snapshot` may be deleted: the manifest has to be editable, and
    /// a VM's Ephemeral baseline is the restore point its every power-off needs.
    func canDeleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) -> Bool {
        canDeleteSnapshots(instance) && !instance.isEphemeralBaseline(snapshot)
    }

    /// Shows the delete-snapshot confirmation.
    func confirmDeleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) {
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
    /// Serialized against the VM's other operations: a revert reads the very
    /// directory this trashes, and half of it landing in the Trash mid-copy is
    /// what that ordering rules out.
    ///
    /// The returned Task lets tests await the trash.
    @discardableResult
    func deleteSnapshotConfirmed(_ instance: VMInstance, snapshot: VMSnapshot) -> Task<Void, Never> {
        let store = snapshotStore
        let id = snapshot.id
        return Task { [weak self] in
            guard let self else { return }
            // Re-checked at the write, not just at the confirmation: the
            // baseline is what every power-off of this VM needs back.
            guard !instance.isEphemeralBaseline(snapshot) else {
                Self.logger.notice(
                    "Refusing to delete snapshot '\(snapshot.name, privacy: .public)': it is the Ephemeral baseline of '\(instance.name, privacy: .public)'"
                )
                return
            }
            do {
                try await self.lifecycle.discardSnapshot(instance, snapshotID: id, store: store)
            } catch {
                Self.logger.error(
                    "Failed to trash snapshot '\(snapshot.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                self.presentError(error)
                return
            }
            var manifest = instance.snapshotManifest
            manifest.remove(id: id)
            self.writeSnapshotManifest(manifest, for: instance)
            Self.logger.notice(
                "Deleted snapshot '\(snapshot.name, privacy: .public)' of VM '\(instance.name, privacy: .public)'"
            )
        }
    }

    /// Renames a snapshot; an empty or unchanged name is a no-op. A
    /// metadata-only manifest write: no VM operation reads it mid-flight, so
    /// it lands whether or not the VM is busy.
    func renameSnapshot(_ snapshot: VMSnapshot, newName: String, on instance: VMInstance) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != snapshot.name else { return }
        var manifest = instance.snapshotManifest
        manifest.rename(id: snapshot.id, to: trimmed)
        guard manifest != instance.snapshotManifest else { return }
        writeSnapshotManifest(manifest, for: instance)
    }

    /// Replaces a snapshot's note; an unchanged value is a no-op. A
    /// metadata-only manifest write: no VM operation reads it mid-flight, so
    /// it lands whether or not the VM is busy.
    ///
    /// Unlike a name, an empty note is a legitimate value — it clears the note.
    /// Leading and trailing whitespace is trimmed; interior newlines are kept.
    func setSnapshotNotes(_ snapshot: VMSnapshot, notes: String, on instance: VMInstance) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != snapshot.notes else { return }
        var manifest = instance.snapshotManifest
        manifest.setNotes(id: snapshot.id, to: trimmed)
        guard manifest != instance.snapshotManifest else { return }
        writeSnapshotManifest(manifest, for: instance)
    }

    /// Bytes each of this VM's snapshots occupies on disk, read off the main
    /// actor — the copies live on the same volume and can be many gigabytes.
    func snapshotOnDiskBytes(for instance: VMInstance) async -> [UUID: UInt64] {
        let store = snapshotStore
        let bundleURL = instance.bundleURL
        let ids = instance.snapshotManifest.snapshots.map(\.id)
        guard !ids.isEmpty else { return [:] }
        return await Task.detached {
            store.onDiskBytes(bundleURL: bundleURL, snapshotIDs: ids)
        }.value
    }

    /// Writes `manifest` to the bundle and mirrors it onto the instance.
    ///
    /// - Returns: Whether it reached disk. On failure the in-memory manifest is
    ///   left alone, so what the UI shows still matches what is stored.
    @discardableResult
    private func writeSnapshotManifest(
        _ manifest: VMSnapshotManifest, for instance: VMInstance
    ) -> Bool {
        do {
            try snapshotStore.saveManifest(manifest, bundleURL: instance.bundleURL)
            instance.snapshotManifest = manifest
            return true
        } catch {
            Self.logger.error(
                "Failed to write the snapshot manifest for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
            return false
        }
    }

    // MARK: - Delete

    /// Begins the delete-VM flow.
    ///
    /// `permanently` selects the destructive variant: `false` (the default) moves
    /// the bundle and the chosen externals to Trash, `true` deletes them
    /// immediately, bypassing it.
    func confirmDelete(_ instance: VMInstance, permanently: Bool = false) {
        presenter?.presentDeleteSheet(for: instance, permanently: permanently)
    }

    /// Deletes the VM bundle and the chosen external files, either to the
    /// Trash or immediately (bypassing it).
    ///
    /// Files shared with other VMs are **never** deleted even if their id is passed
    /// in, so a delete can never break another VM. Externals are deleted *after* the
    /// bundle so the VM disappears from the library even if a downstream op fails;
    /// the returned Tasks let tests await completion.
    @discardableResult
    func deleteConfirmed(
        _ instance: VMInstance, deletingExternalIDs: Set<UUID> = [], permanently: Bool = false
    ) -> [Task<Void, Never>] {
        // A delete sheet is window-modal but doesn't disable the menu bar, so two
        // sheets can be queued for the same VM; the second confirm would hit a
        // missing bundle and surface a spurious error.
        guard instances.contains(where: { $0.id == instance.id }) else {
            Self.logger.debug(
                "Ignoring delete confirm for already-removed VM '\(instance.name, privacy: .public)'"
            )
            return []
        }
        // The sheet is window-modal but leaves the menu key equivalents live, so
        // a Start or Resume can land between opening it and confirming — and a
        // cold resume holds `.paused` with no live VM while it builds its
        // configuration, which `canDelete` alone still reads as deletable.
        // Trashing the bundle then pulls the disk image out from under a guest
        // that is running or about to.
        guard instance.canDelete, !lifecycle.hasActiveOperation(for: instance.id) else {
            Self.logger.notice(
                "Refusing delete of '\(instance.name, privacy: .public)': no longer deletable (status '\(instance.status.displayName, privacy: .public)')"
            )
            return []
        }
        instance.tearDownSession()
        let toDelete =
            deletingExternalIDs.isEmpty
            ? []
            : externalAttachments(for: instance).filter {
                deletingExternalIDs.contains($0.id) && !$0.isShared
            }
        var tasks: [Task<Void, Never>] = []
        do {
            if permanently {
                try storageService.permanentlyDeleteVMBundle(at: instance.bundleURL)
            } else {
                try storageService.deleteVMBundle(at: instance.bundleURL)
            }
            cleanupSetupResumeData(for: instance, permanently: permanently)
            lifecycle.clearActiveOperation(for: instance.id)
            sleepPausedInstanceIDs.remove(instance.id)
            library.evict(instance)
            library.persistOrder()
            if permanently {
                Self.logger.notice("Permanently deleted VM '\(instance.name, privacy: .public)'")
            } else {
                Self.logger.notice("Moved VM '\(instance.name, privacy: .public)' to Trash")
            }
            let vmName = instance.name
            for attachment in toDelete {
                tasks.append(
                    deleteExternalAttachment(
                        at: URL(fileURLWithPath: attachment.path),
                        bookmark: bookmark(for: attachment, in: instance.configuration),
                        label: attachment.label,
                        vmName: vmName,
                        permanently: permanently
                    )
                )
            }
        } catch {
            Self.logger.error(
                "Failed to delete VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
        }
        return tasks
    }

    /// The VM's in-bundle (internal) disks, shown read-only in the delete
    /// sheet's "Removed with the VM" section.
    ///
    /// Falls back to the synthesized main disk when `storageDisks` is `nil`, so a
    /// freshly created VM still shows its `Disk.asif`.
    func bundledDisks(for instance: VMInstance) -> [StorageDisk] {
        (instance.configuration.storageDisks ?? Self.defaultStorageDisks(for: instance))
            .filter(\.isInternal)
    }

    /// `true` when `disk` is the VM's primary (boot) `Disk.asif`.
    ///
    /// Matches by bundle-relative path, so it stays correct on cloned VMs (whose
    /// disk ids are regenerated).
    func isMainDisk(_ disk: StorageDisk, of instance: VMInstance) -> Bool {
        ConfigurationBuilder.isMainBundleDisk(disk, layout: VMBundleLayout(bundleURL: instance.bundleURL))
    }

    /// Returns the external (non-bundle) files referenced by `instance`.
    ///
    /// Each is annotated with the names of other VMs sharing the same path. The
    /// bundled Guest Agent installer DMG is excluded: its path points *inside the
    /// app bundle*, so trashing it would corrupt the app for every VM.
    ///
    /// Existence is **not** resolved — every ``ExternalAttachment/isMissing`` is
    /// `false`; use ``externalAttachmentsResolvingExistence(for:)`` when it matters.
    func externalAttachments(for instance: VMInstance) -> [ExternalAttachment] {
        let agentPath = Self.guestAgentInstallerPath
        var attachments: [ExternalAttachment] = []
        for disk in instance.configuration.storageDisks ?? [] where !disk.isInternal {
            attachments.append(
                ExternalAttachment(
                    id: disk.id,
                    kind: .storageDisk,
                    label: disk.label,
                    path: disk.path,
                    sharedWithVMNames: sharingVMNames(forPath: disk.path, excluding: instance),
                    isMissing: false
                )
            )
        }
        for item in instance.configuration.removableMedia ?? [] where item.path != agentPath {
            attachments.append(
                ExternalAttachment(
                    id: item.id,
                    kind: .removableMedia,
                    label: item.label,
                    path: item.path,
                    sharedWithVMNames: sharingVMNames(forPath: item.path, excluding: instance),
                    isMissing: false
                )
            )
        }
        return attachments
    }

    /// ``externalAttachments(for:)`` with each attachment's
    /// ``ExternalAttachment/isMissing`` resolved against the filesystem.
    ///
    /// The syscalls run detached so a stale or unreachable mount can't freeze the
    /// main actor. Probes go through each attachment's security bookmark — a raw
    /// check on an out-of-container path is sandbox-denied and would render every
    /// row as missing.
    func externalAttachmentsResolvingExistence(for instance: VMInstance) async -> [ExternalAttachment] {
        let attachments = externalAttachments(for: instance)
        guard !attachments.isEmpty else { return attachments }
        let paths = attachments.map(\.path)
        let bookmarks = externalAttachmentRefs(for: instance.configuration)
        let missingByPath = await Task.detached(priority: .userInitiated) {
            var result: [String: Bool] = [:]
            for path in paths where result[path] == nil {
                result[path] = !SecurityScopedBookmark.fileExists(
                    atPath: path, bookmark: bookmarks[path] ?? nil)
            }
            return result
        }.value
        return attachments.map { attachment in
            ExternalAttachment(
                id: attachment.id,
                kind: attachment.kind,
                label: attachment.label,
                path: attachment.path,
                sharedWithVMNames: attachment.sharedWithVMNames,
                isMissing: missingByPath[attachment.path] ?? false
            )
        }
    }

    /// The persisted security bookmark backing an external attachment
    /// (``ExternalAttachment`` itself is a bookmark-free UI projection).
    private func bookmark(
        for attachment: ExternalAttachment, in config: VMConfiguration
    ) -> Data? {
        switch attachment.kind {
        case .storageDisk:
            (config.storageDisks ?? []).first { $0.id == attachment.id }?.bookmark
        case .removableMedia:
            (config.removableMedia ?? []).first { $0.id == attachment.id }?.bookmark
        }
    }

    /// Names of other VMs in the library that reference `path` as an external
    /// storage disk or removable medium.
    ///
    /// Only *external* (non-bundle) storage disks count — bundle-relative paths are
    /// per-VM by construction. `instance` is excluded so the file isn't reported as
    /// shared with itself.
    func sharingVMNames(forPath path: String, excluding instance: VMInstance) -> [String] {
        instances.compactMap { other -> String? in
            guard other.id != instance.id else { return nil }
            let externalDiskPaths = (other.configuration.storageDisks ?? [])
                .filter { !$0.isInternal }
                .map(\.path)
            let mediaPaths = (other.configuration.removableMedia ?? []).map(\.path)
            if externalDiskPaths.contains(path) || mediaPaths.contains(path) {
                return other.name
            }
            return nil
        }
    }

    /// `true` when `item` is the bundled Guest Agent installer DMG.
    ///
    /// The installer lives *inside the app bundle*, so a "remove" of it must only
    /// detach the entry and never trash the file.
    func isGuestAgentInstaller(_ item: RemovableMediaItem) -> Bool {
        guard let agentPath = Self.guestAgentInstallerPath else { return false }
        return item.path == agentPath
    }

    /// Filesystem path of the bundled Guest Agent installer DMG, if present.
    ///
    /// Resolved at the call site (not cached) so it always reflects the running app
    /// bundle's location.
    private static var guestAgentInstallerPath: String? {
        KernovaMacOSAgentInfo.installerDiskImageURL?.path(percentEncoded: false)
    }

    /// `true` when the bundled Guest Agent installer DMG is currently in this
    /// VM's `removableMedia` list (live-attached, pending attach, or cold).
    func isGuestAgentInstallerMounted(on instance: VMInstance) -> Bool {
        guard let path = Self.guestAgentInstallerPath else { return false }
        return (instance.configuration.removableMedia ?? []).contains { $0.path == path }
    }

    /// Trashes any in-progress image download bundle for a VM that's being
    /// deleted.
    ///
    /// Every setup source that fetches its image — a macOS restore image from
    /// any of its three downloading sources, or a Linux installer ISO — writes
    /// the same `.kernovadownload` sidecar, so all of them are covered; the
    /// "delete externals" toggle does not gate it, and the disposition matches
    /// the VM's own. The completed image at `downloadDestinationPath` lives at a
    /// user-known path and is left alone.
    private func cleanupSetupResumeData(for instance: VMInstance, permanently: Bool) {
        if let context = instance.configuration.installContext,
            context.source.downloadsImage,
            let destinationURL = context.downloadDestinationURL
        {
            lifecycle.ipswService.discardResumeData(at: destinationURL, permanently: permanently)
        } else if let destinationURL = instance.configuration.linuxInstallContext?
            .downloadDestinationURL
        {
            lifecycle.downloadService.discardResumeData(
                at: destinationURL, permanently: permanently)
        } else {
            return
        }
        Self.logger.notice(
            "Discarded in-progress download bundle for deleted VM '\(instance.name, privacy: .public)'"
        )
    }

    /// Detached delete for a single external attachment, to Trash or
    /// immediately depending on `permanently`.
    ///
    /// Missing files are swallowed at `.notice` (the source may have been moved or
    /// deleted out-of-band); other failures log `.warning` and surface a single
    /// error alert on the MainActor.
    private func deleteExternalAttachment(
        at url: URL, bookmark: Data?, label: String, vmName: String, permanently: Bool
    ) -> Task<Void, Never> {
        let fileSystem = fileSystem
        return Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try SecurityScopedBookmark.withResolvedURL(bookmark: bookmark, fallback: url) {
                    target in
                    if permanently {
                        try fileSystem.removeItem(at: target)
                    } else {
                        try fileSystem.trashItem(at: target)
                    }
                }
                Self.logger.notice(
                    "Deleted external attachment '\(label, privacy: .public)' for deleted VM '\(vmName, privacy: .public)'"
                )
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                Self.logger.notice(
                    "External attachment already gone for '\(label, privacy: .public)' (\(url.lastPathComponent, privacy: .public)) on deleted VM '\(vmName, privacy: .public)'; skipping delete"
                )
            } catch {
                let message = error.localizedDescription
                Self.logger.warning(
                    "Failed to delete external attachment '\(label, privacy: .public)' (\(url.lastPathComponent, privacy: .public)) on deleted VM '\(vmName, privacy: .public)': \(message, privacy: .public)"
                )
                await MainActor.run { [weak self] in
                    self?.surfaceError(message)
                }
            }
        }
    }

    // MARK: - Preparing Rows (shared by Clone & Import)

    /// Bounds the blocking bundle copies import and clone run.
    ///
    /// Uncapped, a large multi-select drop would spawn N concurrent blocking
    /// `FileManager` calls on Swift's cooperative pool and saturate it. The cap is
    /// deliberately small — copies serialize at the device anyway, so a low bound
    /// avoids cross-volume disk thrash without losing throughput.
    private static let copyQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Runs blocking file work off the cooperative pool on the bounded ``copyQueue``, awaiting its
    /// result.
    private static func runBoundedCopy<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            copyQueue.addOperation {
                continuation.resume(with: Result(catching: work))
            }
        }
    }

    // MARK: - Import

    /// Reserves a collision-free destination for one `.kernova` bundle, registers its phantom row
    /// synchronously, and spawns the file copy — a no-op when the source is already in the library
    /// by UUID.
    ///
    /// Everything before the copy `Task` is spawned is synchronous (no `await`), so a batch's
    /// reservations — and two overlapping triggers' — run atomically on the MainActor and see each
    /// other's phantoms in `instances`; the copies then run concurrently.
    private func reserveAndImport(from sourceURL: URL) {
        do {
            let vmsDir = try storageService.vmsDirectory
            var config = try storageService.loadConfiguration(from: sourceURL)

            // Auto-start is the one setting that runs a guest with no user
            // action, so it is local intent rather than something a bundle
            // carries in: a VM arriving pre-marked would boot on the next
            // launch without ever being asked for. The local user marks it.
            let arrivedMarkedForAutoStart = config.startsAutomaticallyOnLaunch
            config.startsAutomaticallyOnLaunch = false

            // Already in the library by UUID (including a source already inside the VMs
            // directory) — select it rather than re-importing.
            if let existing = instances.first(where: { $0.id == config.id }) {
                selectedID = existing.id
                Self.logger.info(
                    "VM '\(config.name, privacy: .public)' already in library — selected existing instance")
                return
            }

            // The save file has to come from the source bundle — the destination doesn't exist yet.
            let sourceLayout = VMBundleLayout(bundleURL: sourceURL)
            let initialStatus = VMLibrary.initialStatus(for: config, layout: sourceLayout)

            let destinationURL = library.reserveDestination(for: sourceURL, in: vmsDir)
            let phantom = VMInstance(
                configuration: config, bundleURL: destinationURL, status: initialStatus,
                preferences: preferences)

            let storage = storageService
            let sanitizedConfig = config
            library.prepareBundle(
                phantom, operation: .importing,
                copyWork: {
                    try await Self.runBoundedCopy {
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    }
                    // The copy reproduces the source `config.json` verbatim, so
                    // the cleared flag only reaches disk by writing it back.
                    if arrivedMarkedForAutoStart {
                        try storage.saveConfiguration(sanitizedConfig, to: destinationURL)
                    }
                },
                onSuccess: { [weak self] in
                    // The phantom was wired before its bundle existed, so any
                    // snapshots that arrived with the copy are read now.
                    self?.reloadSnapshots(for: phantom)
                    Self.logger.notice(
                        "Imported VM '\(config.name, privacy: .public)' from \(sourceURL.lastPathComponent, privacy: .public)"
                    )
                })
        } catch {
            Self.logger.error(
                "Failed to import VM from \(sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
        }
    }

    /// Filters `urls` to `.kernova` bundles and imports the batch.
    ///
    /// Each bundle's destination is reserved and its phantom row registered synchronously (see
    /// ``reserveAndImport(from:)``), so two overlapping triggers never collide on a destination
    /// name and never wait behind each other's copies.
    ///
    /// Returns whether any bundle was accepted for import — `true` means at least one
    /// bundle was reserved, not that every import will succeed.
    @discardableResult
    func importVMs(fromDroppedURLs urls: [URL]) -> Bool {
        let bundles = urls.filter { VMStorageService.isBundleURL($0) }
        guard !bundles.isEmpty else { return false }
        Self.logger.notice("Importing \(bundles.count, privacy: .public) bundle(s)")
        for url in bundles {
            reserveAndImport(from: url)
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
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Self.logger.debug(
                "Committing rename of '\(instance.name, privacy: .public)' to '\(trimmed, privacy: .public)'"
            )
            updateConfiguration(of: instance) { $0.name = trimmed }
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
            var disks = config.storageDisks ?? Self.defaultStorageDisks(for: instance)
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
            var disks = config.storageDisks ?? Self.defaultStorageDisks(for: instance)
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
            var disks = config.storageDisks ?? Self.defaultStorageDisks(for: instance)
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

    /// Returns the storage disks list to render when `storageDisks` is
    /// `nil` / empty.
    ///
    /// The settings view uses this so the user always sees the main disk as a row,
    /// and mutating helpers fall back to it when initializing the list on first edit.
    static func defaultStorageDisks(for instance: VMInstance) -> [StorageDisk] {
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        return [ConfigurationBuilder.defaultMainDisk(layout: layout)]
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
                    var disks = config.storageDisks ?? Self.defaultStorageDisks(for: instance)
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
        guard instance.status.canEditSettings else {
            Self.logger.debug(
                "Clone skipped for '\(instance.name, privacy: .public)': status '\(instance.status.displayName, privacy: .public)' does not allow editing"
            )
            return
        }
        let generateNewID = generateNewMachineID ?? preferences.cloneGeneratesNewMachineID
        let existingNames = instances.map(\.configuration.name)
        var clonedConfig = instance.configuration.clonedForNewInstance(existingNames: existingNames)

        clonedConfig.macAddress = VZMACAddress.randomLocallyAdministered().string

        if generateNewID {
            if clonedConfig.guestOS == .macOS {
                clonedConfig.machineIdentifierData = VZMacMachineIdentifier().dataRepresentation
            }
            if clonedConfig.bootMode == .efi || clonedConfig.bootMode == .linuxKernel {
                clonedConfig.genericMachineIdentifierData = VZGenericMachineIdentifier().dataRepresentation
            }
        } else {
            // Keep mode mints only what there is no identity to keep: a source
            // whose identifier lives in the bundle file alone hands it to the
            // clone through `filesToCopy` below, untouched here.
            if clonedConfig.guestOS == .macOS, instance.effectiveMachineIdentifierData == nil {
                clonedConfig.machineIdentifierData = VZMacMachineIdentifier().dataRepresentation
                Self.logger.notice(
                    "Clone of '\(instance.name, privacy: .public)' had no machine identifier to keep — generated a new one"
                )
            }
            if clonedConfig.bootMode == .efi || clonedConfig.bootMode == .linuxKernel,
                clonedConfig.genericMachineIdentifierData == nil
            {
                clonedConfig.genericMachineIdentifierData = VZGenericMachineIdentifier().dataRepresentation
                Self.logger.notice(
                    "Clone of '\(instance.name, privacy: .public)' had no generic machine identifier to keep — generated a new one"
                )
            }
        }

        var filesToCopy = ["Disk.asif"]
        switch clonedConfig.guestOS {
        case .macOS:
            filesToCopy.append(contentsOf: ["AuxiliaryStorage", "HardwareModel"])
            if !generateNewID {
                filesToCopy.append("MachineIdentifier")
            }
        case .linux:
            if clonedConfig.bootMode == .efi {
                filesToCopy.append("EFIVariableStore")
            }
        }

        // The main bundle disk lives at a fixed relative path, so only
        // `AdditionalDisks/<id>.asif` entries need remapping — their cloned ids
        // differ from the originals.
        let originalDisks = instance.configuration.storageDisks ?? []
        let clonedDisks = clonedConfig.storageDisks ?? []
        let internalDiskMapping: [(sourceID: UUID, clonedDisk: StorageDisk)] = zip(originalDisks, clonedDisks)
            .compactMap { original, cloned in
                guard cloned.isInternal, cloned.path.hasPrefix("AdditionalDisks/") else { return nil }
                return (sourceID: original.id, clonedDisk: cloned)
            }

        let bundleURL: URL
        do {
            bundleURL = try storageService.bundleURL(for: clonedConfig)
        } catch {
            Self.logger.error(
                "Failed to derive bundle URL for clone of '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
            return
        }

        let phantom = VMInstance(
            configuration: clonedConfig, bundleURL: bundleURL, preferences: preferences)

        let sourceBundleURL = instance.bundleURL
        let sourceName = instance.name
        let config = clonedConfig
        let storage = storageService
        let diskMapping = internalDiskMapping
        let bundleFilesToCopy = filesToCopy
        library.prepareBundle(
            phantom, operation: .cloning,
            copyWork: {
                let log = Self.logger
                let skippedDiskIDs: Set<UUID> = try await Self.runBoundedCopy {
                    let resultURL = try storage.cloneVMBundle(
                        from: sourceBundleURL, newConfiguration: config, filesToCopy: bundleFilesToCopy)

                    if let machineIDData = config.machineIdentifierData, config.guestOS == .macOS {
                        let layout = VMBundleLayout(bundleURL: resultURL)
                        try machineIDData.write(to: layout.machineIdentifierURL, options: .atomic)
                    }

                    var skipped: Set<UUID> = []
                    if !diskMapping.isEmpty {
                        let sourceLayout = VMBundleLayout(bundleURL: sourceBundleURL)
                        let destLayout = VMBundleLayout(bundleURL: resultURL)
                        let fm = FileManager.default
                        try fm.createDirectory(
                            at: destLayout.additionalDisksDirectoryURL, withIntermediateDirectories: true)
                        for mapping in diskMapping {
                            let sourceFile = sourceLayout.additionalDiskURL(id: mapping.sourceID)
                            let destFile = destLayout.additionalDiskURL(id: mapping.clonedDisk.id)
                            if fm.fileExists(atPath: sourceFile.path(percentEncoded: false)) {
                                try fm.copyItem(at: sourceFile, to: destFile)
                            } else {
                                log.warning(
                                    "Internal disk '\(mapping.clonedDisk.label, privacy: .public)' source file missing at '\(sourceFile.lastPathComponent, privacy: .public)' — removing from clone"
                                )
                                skipped.insert(mapping.clonedDisk.id)
                            }
                        }
                    }
                    return skipped
                }

                // `clonedForNewInstance` gives every disk a fresh `id` but copies its
                // `path` verbatim, while the copy above wrote each file to
                // `AdditionalDisks/<new-id>.asif` — without this remap, boot-time
                // resolution looks for the source bundle's id and fails with
                // `storageDiskNotFound`.
                if !diskMapping.isEmpty {
                    let remappedPaths: [UUID: String] = Dictionary(
                        uniqueKeysWithValues: diskMapping.map { mapping in
                            (mapping.clonedDisk.id, "AdditionalDisks/\(mapping.clonedDisk.id.uuidString).asif")
                        }
                    )
                    phantom.configuration.storageDisks = phantom.configuration.storageDisks?
                        .filter { !skippedDiskIDs.contains($0.id) }
                        .map { disk in
                            guard let newPath = remappedPaths[disk.id] else { return disk }
                            var updated = disk
                            updated.path = newPath
                            return updated
                        }
                    if phantom.configuration.storageDisks?.isEmpty == true {
                        phantom.configuration.storageDisks = nil
                    }
                    try storage.saveConfiguration(phantom.configuration, to: phantom.bundleURL)
                }
            },
            onSuccess: {
                Self.logger.notice(
                    "Cloned VM '\(sourceName, privacy: .public)' as '\(config.name, privacy: .public)'")
            })
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
    /// the status — ``start(_:)`` dispatches on the surviving install context
    /// too, so a failed install sitting at `.error` still routes into the
    /// installer, and `.error` otherwise means "retry the boot".
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
    /// start, and the duplicate machine-ID and MAC refusals inside ``start(_:)``
    /// and ``resume(_:)`` compare against VMs that are already live, so they only
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

    // MARK: - Cancel Preparing

    func confirmCancelPreparing(_ instance: VMInstance) {
        presenter?.presentCancelPreparing(for: instance)
    }

    func cancelPreparingConfirmed(_ instance: VMInstance) {
        guard var state = instance.preparingState else {
            // The copy settled before the user confirmed — nothing is in flight, so
            // remove the row and trash the completed bundle here.
            library.cleanupPhantomInstance(instance)
            return
        }
        guard !state.isCancelling else { return }  // already cancelling

        // Mark the row "Cancelling…" but keep it in `instances`: the copy is uninterruptible, so
        // removing it now would race the still-writing copy and briefly drop `hasPreparing`,
        // letting reconcile resurrect the bundle. The copy task cleans up once it settles.
        state.task.cancel()
        state.isCancelling = true
        instance.preparingState = state

        Self.logger.notice(
            "Cancelling \(state.operation.displayNoun, privacy: .public) for '\(instance.name, privacy: .public)'")
    }

    // MARK: - Error Handling

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
