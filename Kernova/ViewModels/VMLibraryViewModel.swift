import Foundation
import Virtualization
import os

/// Central view model managing the list of all VMs and lifecycle operations.
@MainActor
@Observable
final class VMLibraryViewModel {
    nonisolated private static let logger = Logger(subsystem: "app.kernova", category: "VMLibraryViewModel")
    static let lastSelectedVMIDKey = "lastSelectedVMID"
    static let vmOrderKey = "vmOrder"

    // MARK: - Services

    let storageService: any VMStorageProviding
    let diskImageService: any DiskImageProviding
    let lifecycle: VMLifecycleCoordinator

    // MARK: - State

    var instances: [VMInstance] = []
    var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            if let selectedID {
                UserDefaults.standard.set(selectedID.uuidString, forKey: Self.lastSelectedVMIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastSelectedVMIDKey)
            }
        }
    }

    /// Presentation delegate for alerts, sheets, and the creation wizard.
    ///
    /// Set by `DetailContainerViewController`. The view model calls these
    /// methods imperatively instead of toggling observed `show*` flags. Errors
    /// raised before a presenter is attached (e.g. the initial `loadVMs()` in
    /// `init`) are buffered and flushed when one is set.
    @ObservationIgnored weak var presenter: (any VMLibraryPresenting)? {
        didSet {
            guard presenter != nil, !bufferedErrorMessages.isEmpty else { return }
            let buffered = bufferedErrorMessages
            bufferedErrorMessages.removeAll()
            buffered.forEach { presenter?.presentError($0) }
        }
    }

    /// Error messages raised while `presenter` was nil, flushed when it is set.
    @ObservationIgnored private var bufferedErrorMessages: [String] = []

    /// VMs with an in-flight removable-media reconciliation Task.
    ///
    /// Together with `pendingRemovableMediaTarget`, implements a
    /// coalesce-and-drain loop so multiple rapid edits to the removable
    /// media list collapse to a single in-flight Task per instance that
    /// always converges on the latest configuration. Without this, two
    /// `await` suspensions inside `applyLiveRemovableMediaChange`
    /// (detach, attach) leave the actor reentrant and let a second Task
    /// read the same tracking and issue duplicate operations.
    private var reconcilingRemovableMediaInstances: Set<UUID> = []

    /// Latest desired removable media list per instance, written every
    /// time `applyLivePolicy` sees a list change on a running/paused VM
    /// and drained by `runRemovableMediaReconciliation` until empty.
    private var pendingRemovableMediaTarget: [UUID: [RemovableMediaItem]] = [:]
    var activeRename: RenameTarget?

    /// `true` when any instance is mid-clone or mid-import.
    var hasPreparing: Bool { instances.contains(where: \.isPreparing) }

    /// Current VM ordering used by sortInstances(); synchronized with UserDefaults via persistOrder().
    private var customOrder: [UUID] = []

    /// Bundle names whose load failures have already been reported to the user.
    ///
    /// Prevents repeated error dialogs for persistently corrupted bundles across successive
    /// `reconcileWithDisk()` calls. Populated by both `loadVMs()` and `reconcileWithDisk()`.
    /// Reset on full reload (`loadVMs`), when a previously-failed bundle loads successfully,
    /// or when a bundle is removed from disk.
    private var reportedFailedBundles: Set<String> = []

    /// Called when a VM with a non-inline `displayPreference` is about to start or resume,
    /// allowing the app delegate to pre-create the display window with a spinner.
    @ObservationIgnored var onOpenDisplayWindow: ((VMInstance) -> Void)?

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
        storageService: any VMStorageProviding = VMStorageService(),
        diskImageService: any DiskImageProviding = DiskImageService(),
        virtualizationService: any VirtualizationProviding = VirtualizationService(),
        installService: any MacOSInstallProviding = MacOSInstallService(),
        ipswService: any IPSWProviding = IPSWService(),
        usbDeviceService: any USBDeviceProviding = USBDeviceService()
    ) {
        self.storageService = storageService
        self.diskImageService = diskImageService
        self.lifecycle = VMLifecycleCoordinator(
            virtualizationService: virtualizationService,
            installService: installService,
            ipswService: ipswService,
            usbDeviceService: usbDeviceService
        )

        loadVMs()
        startDirectoryWatcher()
        startSleepWatcher()
    }

    // MARK: - Initial Status

    /// Status to assign to a VM when it's first loaded from disk or imported.
    /// `.initialBoot` takes priority over `.paused`/`.stopped` whenever an
    /// install context is still on file — that's the canonical signal that the
    /// VM has never completed its initial boot.
    static func initialStatus(for config: VMConfiguration, layout: VMBundleLayout) -> VMStatus {
        if config.installContext != nil {
            return .initialBoot
        }
        return layout.hasSaveFile ? .paused : .stopped
    }

    // MARK: - Load

    func loadVMs() {
        reportedFailedBundles.removeAll()
        do {
            let bundles = try storageService.listVMBundles()
            var failedBundles: [String] = []
            instances = bundles.compactMap { bundleURL in
                do {
                    let config = try storageService.loadConfiguration(from: bundleURL)
                    let layout = VMBundleLayout(bundleURL: bundleURL)
                    let initialStatus = Self.initialStatus(for: config, layout: layout)
                    let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: initialStatus)
                    wirePersistence(for: instance)
                    return instance
                } catch {
                    Self.logger.error(
                        "Failed to load VM from \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    failedBundles.append(bundleURL.deletingPathExtension().lastPathComponent)
                    return nil
                }
            }
            if !failedBundles.isEmpty {
                reportedFailedBundles.formUnion(failedBundles)
                presentError(LoadError.bundleLoadFailed(names: failedBundles))
            }

            // Load persisted order, sort by it, then normalize customOrder to match
            // the actual instance list (prunes stale UUIDs, incorporates new VMs).
            if let savedStrings = UserDefaults.standard.stringArray(forKey: Self.vmOrderKey) {
                customOrder = savedStrings.compactMap { UUID(uuidString: $0) }
                Self.logger.debug("Loaded custom VM order: \(self.customOrder.count, privacy: .public) UUID(s)")
            } else {
                Self.logger.debug("No custom VM order found — using default createdAt sort")
            }
            sortInstances()
            customOrder = instances.map(\.id)

            if selectedID == nil || !instances.contains(where: { $0.id == selectedID }) {
                if let savedString = UserDefaults.standard.string(forKey: Self.lastSelectedVMIDKey),
                    let savedID = UUID(uuidString: savedString),
                    instances.contains(where: { $0.id == savedID })
                {
                    selectedID = savedID
                    Self.logger.debug("Restored last-selected VM from UserDefaults: \(savedID.uuidString)")
                } else {
                    selectedID = instances.first?.id
                }
            }
            Self.logger.notice("Loaded \(self.instances.count, privacy: .public) VMs")
        } catch {
            Self.logger.error("Failed to load VM library: \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    // MARK: - Create

    /// Creates a VM bundle and disk image from a wizard model, optionally
    /// auto-starting it.
    ///
    /// Returns `.success` on success, or `.failure(error)` if bundle/disk
    /// creation failed. The error is returned (not presented) so the wizard host
    /// can show it on the wizard's own sheet and keep it open for a retry.
    @discardableResult
    func createVM(from wizard: VMCreationViewModel) async -> Result<Void, Error> {
        do {
            var config = wizard.buildConfiguration()

            // For macOS guests, persist the install intent so the next Start
            // can drive the install pipeline (and download resume) without
            // the wizard. Linux guests have no Kernova-managed install step.
            if config.guestOS == .macOS {
                config.installContext = wizard.buildInstallContext()
            }

            let bundleURL = try storageService.createVMBundle(for: config)
            let layout = VMBundleLayout(bundleURL: bundleURL)
            let initialStatus = Self.initialStatus(for: config, layout: layout)
            let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: initialStatus)
            wirePersistence(for: instance)

            // Create disk image
            try await diskImageService.createDiskImage(
                at: instance.diskImageURL,
                sizeInGB: config.diskSizeInGB
            )

            instances.append(instance)
            persistOrder()
            selectedID = instance.id

            Self.logger.notice(
                "Created VM '\(config.name, privacy: .public)' (status: \(initialStatus.displayName, privacy: .public))"
            )

            if wizard.startAfterCreate {
                // For macOS VMs with an installContext, `start(_:)` routes
                // through `installAndAutoBoot` which kicks off an install
                // Task and returns immediately. For other VMs, it awaits
                // the VZ start. Errors are surfaced by `start(_:)` via
                // `presentError`, so the wizard's caller can dismiss as
                // soon as `createVM` returns.
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

    // MARK: - macOS Installation

    /// Drives the install pipeline for an `.initialBoot` (or `.error` with
    /// `installContext`) VM and, on success, chains an auto-boot.
    ///
    /// Non-cancel errors leave the VM in `.error` so the user sees the message;
    /// cancel returns it to `.initialBoot` for a future retry that will resume
    /// the download from the `.resumedata` sidecar if present.
    private func installAndAutoBoot(_ instance: VMInstance) {
        guard let context = instance.configuration.installContext else {
            assertionFailure("installAndAutoBoot called without installContext")
            return
        }
        if instance.installTask != nil { return }  // guard against rapid double-click
        instance.installTask = Task { [weak self] in
            guard let self else { return }
            // Caller owns installTask cleanup; defer nils it out on every exit
            // path (success, cancel, error) so the coordinator doesn't have to.
            defer { instance.installTask = nil }
            do {
                try await self.lifecycle.installMacOS(on: instance, context: context)
                // `installMacOS` cleared both `installContext` and
                // `installState` on its success path; this is a
                // belt-and-braces redundant clear so a future refactor
                // that relocates the coordinator-level cleanup doesn't
                // silently leave install-progress UI armed. `start(_:)`
                // now sees no installContext and goes down the normal
                // boot path (via the post-install hand-off branch).
                instance.installState = nil
                await self.start(instance)
            } catch is CancellationError {
                // Tear down the VM if `MacOSInstallService.install` attached
                // one before cancellation fired (i.e. cancel landed during
                // `installer.install()` rather than the download phase).
                // Without this, retry would build a fresh
                // `VZMacAuxiliaryStorage(contentsOf:)` while the old one is
                // still alive on `instance.virtualMachine` — same lock race
                // this PR closes for the success path.
                instance.tearDownSession()
                instance.installState = nil
                instance.errorMessage = nil
                instance.status = .initialBoot
                Self.logger.notice(
                    "Install cancelled for '\(instance.name, privacy: .public)' — VM remains in .initialBoot"
                )
            } catch {
                // Same teardown rationale as the cancel branch above:
                // whether the user cancelled (race branch below) or the
                // pipeline failed for real, an attached VM from a partial
                // install must not bleed into the next retry.
                instance.tearDownSession()
                instance.installState = nil
                if Task.isCancelled {
                    // The user cancelled and a non-cancellation error arrived
                    // before the cancel propagated (e.g. a network failure
                    // raced the cancel). The coordinator's generic catch set
                    // status to `.error`; user intent was cancel, so route
                    // back to `.initialBoot` and drop the error message —
                    // the VM stays ready for retry, no dialog.
                    instance.errorMessage = nil
                    instance.status = .initialBoot
                    Self.logger.notice(
                        "Install cancelled for '\(instance.name, privacy: .public)' — pipeline surfaced \(error.localizedDescription, privacy: .public)"
                    )
                } else {
                    Self.logger.error(
                        "Install failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                    )
                    self.presentError(error)
                }
            }
        }
    }

    /// Cancels an in-progress macOS install.
    ///
    /// The VM returns to `.initialBoot` so a subsequent Start can resume
    /// (downloads pick up from the `.resumedata` sidecar at the chosen path).
    /// Bundle is preserved. For destructive removal, use the existing delete
    /// flow ("Move to Trash").
    func cancelInstallation(_ instance: VMInstance) {
        Self.logger.info("Cancelling installation for '\(instance.name, privacy: .public)'")
        instance.installTask?.cancel()
        // installAndAutoBoot's CancellationError catch handles the status
        // transition to .initialBoot and installState cleanup. Don't duplicate
        // that work here, and don't trash the bundle — non-destructive cancel.
    }

    // MARK: - Lifecycle

    func start(_ instance: VMInstance, bootIntoRecovery: Bool = false) async {
        // VMs awaiting initial boot route through the install pipeline. The
        // pipeline clears installContext on success and chains an auto-boot;
        // failure leaves .error / .initialBoot, ready for the user to retry.
        // Check by installContext (not status) so .error retries also dispatch.
        // Recovery boots never reach here — they're gated to stopped (installed)
        // macOS guests, which have no installContext.
        if instance.configuration.installContext != nil {
            installAndAutoBoot(instance)
            return
        }

        if instance.configuration.displayPreference != .inline {
            onOpenDisplayWindow?(instance)
        }
        do {
            try await lifecycle.start(instance, bootIntoRecovery: bootIntoRecovery)
        } catch {
            Self.logger.error(
                "Failed to start '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    func stop(_ instance: VMInstance) {
        // VZ rejects requestStop() on paused VMs ("Invalid virtual machine state").
        // Surface a confirmation sheet offering resume-and-shutdown or force-stop instead.
        if instance.status == .paused && !instance.isColdPaused {
            presenter?.presentStopPaused(for: instance)
            return
        }
        do {
            try lifecycle.stop(instance)
        } catch {
            Self.logger.error(
                "Failed to stop '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    /// Resumes a paused VM then requests a graceful ACPI shutdown.
    ///
    /// Used by the
    /// stop-paused confirmation sheet's "Resume and Shut Down" action.
    ///
    /// Note: `lifecycle.resume` is serialized through the lifecycle coordinator,
    /// but `lifecycle.stop` deliberately bypasses serialization (so users can
    /// always interrupt a hung op). The two calls are therefore not atomic; in
    /// practice the UI gates lifecycle buttons during transitions, so an
    /// interleaved op is not reachable through normal user input.
    func resumeAndStop(_ instance: VMInstance) async {
        do {
            try await lifecycle.resume(instance)
            try lifecycle.stop(instance)
        } catch {
            Self.logger.error(
                "Failed to resume-and-stop '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
        }
    }

    /// Force-stops a paused VM via the stop-paused confirmation sheet's "Force Stop" action.
    /// Wrapper around `forceStop` that clears the alert state, matching `deleteConfirmed`'s pattern.
    func forceStopFromPaused(_ instance: VMInstance) async {
        await forceStop(instance)
    }

    func forceStop(_ instance: VMInstance) async {
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
    ///
    /// The affordance is gated in the UI by `VMInstance.canStartInRecovery`.
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
        if instance.configuration.displayPreference != .inline {
            onOpenDisplayWindow?(instance)
        }
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

    // MARK: - Delete

    /// Begins the delete-VM flow.
    ///
    /// Always presents the unified delete sheet, which lists the VM's
    /// in-bundle disks (removed with the VM) and any external files (each
    /// individually selectable for deletion). There is no longer a separate
    /// "simple alert" path: every VM has at least its main disk to show.
    ///
    /// `permanently` selects the destructive variant: when `false` (the
    /// default) the bundle and chosen externals are moved to Trash; when
    /// `true` they are deleted immediately, bypassing the Trash. The sheet
    /// reflects the mode and routes back through ``deleteConfirmed(_:deletingExternalIDs:permanently:)``.
    func confirmDelete(_ instance: VMInstance, permanently: Bool = false) {
        presenter?.presentDeleteSheet(for: instance, permanently: permanently)
    }

    /// Deletes the VM bundle and the chosen external files, either to the
    /// Trash or immediately (bypassing it).
    ///
    /// Bundle-internal disks ride along inside the deleted bundle. External
    /// storage disks and removable media live outside the bundle, so each
    /// one whose `id` is in `deletingExternalIDs` is removed via a detached
    /// Task (mirroring `removeStorageDisk` / `removeRemovableMedia` — see
    /// those for the rationale on `Task.detached`). `permanently` is threaded
    /// through to both the bundle and the externals so the whole operation
    /// uses one disposition.
    ///
    /// Files shared with other VMs are **never** deleted even if their id is
    /// passed in: the sheet locks their toggle off, and this guard enforces
    /// the same invariant at the model layer so a delete can never break
    /// another VM. Externals are deleted *after* the bundle so the VM
    /// disappears from the library even if a downstream op fails, and the
    /// returned Tasks let tests await completion.
    @discardableResult
    func deleteConfirmed(
        _ instance: VMInstance, deletingExternalIDs: Set<UUID> = [], permanently: Bool = false
    ) -> [Task<Void, Never>] {
        // Guard against a stale repeat confirm: a delete sheet is window-modal but
        // doesn't disable the menu bar, so the user can queue two delete sheets for
        // the same VM. Once the first removes it, a second confirm would hit a missing
        // bundle (`bundleNotFound`) and surface a spurious error — bail instead.
        guard instances.contains(where: { $0.id == instance.id }) else {
            Self.logger.debug(
                "Ignoring delete confirm for already-removed VM '\(instance.name, privacy: .public)'"
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
            cleanupInstallResumeData(for: instance, permanently: permanently)
            lifecycle.clearActiveOperation(for: instance.id)
            sleepPausedInstanceIDs.remove(instance.id)
            instances.removeAll { $0.id == instance.id }
            persistOrder()
            if selectedID == instance.id {
                selectedID = instances.first?.id
            }
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
    /// Falls back to the synthesized main disk when `storageDisks` is `nil`
    /// (the same default `removeStorageDisk` uses), so a freshly created VM
    /// still shows its `Disk.asif`. External disks are excluded — those are
    /// the user's individually selectable attachments.
    func bundledDisks(for instance: VMInstance) -> [StorageDisk] {
        (instance.configuration.storageDisks ?? Self.defaultStorageDisks(for: instance))
            .filter(\.isInternal)
    }

    /// `true` when `disk` is the VM's primary (boot) `Disk.asif`.
    ///
    /// Used to warn before removing the disk the VM starts from. Delegates to
    /// `ConfigurationBuilder.isMainBundleDisk`, which matches by bundle-relative
    /// path so it stays correct on cloned VMs (whose disk ids are regenerated).
    func isMainDisk(_ disk: StorageDisk, of instance: VMInstance) -> Bool {
        ConfigurationBuilder.isMainBundleDisk(disk, layout: VMBundleLayout(bundleURL: instance.bundleURL))
    }

    /// Returns the external (non-bundle) files referenced by `instance`.
    ///
    /// Each attachment is annotated with the names of any other VMs in
    /// the library that reference the same path. The shared-with list
    /// lets the delete confirmation warn before trashing a file that
    /// another VM still depends on (e.g., a shared installer ISO).
    ///
    /// The bundled Guest Agent installer DMG is deliberately excluded: it
    /// is mounted as a read-only `RemovableMediaItem` whose path points
    /// *inside the app bundle* (see ``mountGuestAgentInstaller(on:purpose:)``), so
    /// it is never a user-owned file. Surfacing it in the delete sheet is
    /// meaningless, and trashing it would corrupt the app bundle and break
    /// Guest Agent installation for every VM in the library. Identified by
    /// path equality with `KernovaGuestAgentInfo.installerDiskImageURL`,
    /// the same mechanism ``unmountGuestAgentInstaller(from:)`` uses.
    ///
    /// Existence is **not** resolved here — every attachment's
    /// ``ExternalAttachment/isMissing`` is left `false`. This keeps the method
    /// free of filesystem syscalls so it stays cheap on the main actor (the
    /// delete fan-out in ``deleteConfirmed(_:deletingExternalIDs:permanently:)`` only
    /// needs id/sharing). The delete sheet, which *does* surface missing-file state,
    /// uses ``externalAttachmentsResolvingExistence(for:)`` to fill `isMissing`
    /// off-main.
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
    /// The `FileManager.fileExists` syscalls run on a detached task so a stale
    /// or unreachable mount can't freeze the main actor while the delete sheet
    /// is assembled — the same reason ``AttachmentFileMonitor`` probes off-main.
    /// Used by `DetailAlertsPresenter` before presenting the sheet.
    func externalAttachmentsResolvingExistence(for instance: VMInstance) async -> [ExternalAttachment] {
        let attachments = externalAttachments(for: instance)
        guard !attachments.isEmpty else { return attachments }
        let paths = attachments.map(\.path)
        let missingByPath = await Task.detached(priority: .userInitiated) {
            var result: [String: Bool] = [:]
            for path in paths where result[path] == nil {
                result[path] = !FileManager.default.fileExists(atPath: path)
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

    /// Names of other VMs in the library that reference `path` as an external
    /// storage disk or removable medium.
    ///
    /// The single source of truth for "who else uses this file", shared by the
    /// VM-delete sheet (``externalAttachments(for:)``) and the per-row delete
    /// confirmations in settings. Only *external* (non-bundle) storage disks
    /// count — bundle-relative paths are per-VM by construction. `instance` is
    /// excluded so the file isn't reported as shared with itself.
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
    /// The installer lives *inside the app bundle* and is mounted read-only by
    /// ``mountGuestAgentInstaller(on:purpose:)``; it is never a user-owned file, so a
    /// "remove" of it must only detach the entry and never trash the file.
    /// Identified by path equality, the same mechanism the delete flow uses.
    func isGuestAgentInstaller(_ item: RemovableMediaItem) -> Bool {
        guard let agentPath = Self.guestAgentInstallerPath else { return false }
        return item.path == agentPath
    }

    /// Filesystem path of the bundled Guest Agent installer DMG, if present.
    ///
    /// Resolved at the call site (not cached) so it always reflects the
    /// running app bundle's location. `nil` when the DMG is missing — in
    /// that case nothing is filtered, which is correct: there is no bundled
    /// resource to protect. Mirrors the path-equality identity used by
    /// ``mountGuestAgentInstaller(on:purpose:)`` / ``unmountGuestAgentInstaller(from:)``.
    private static var guestAgentInstallerPath: String? {
        KernovaGuestAgentInfo.installerDiskImageURL?.path(percentEncoded: false)
    }

    /// `true` when the bundled Guest Agent installer DMG is currently in this
    /// VM's `removableMedia` list (live-attached, pending attach, or cold).
    ///
    /// Drives the menubar item's attach-vs-eject mode and is the shared
    /// path-equality check used by ``mountGuestAgentInstaller(on:purpose:)`` /
    /// ``unmountGuestAgentInstaller(from:)``.
    func isGuestAgentInstallerMounted(on instance: VMInstance) -> Bool {
        guard let path = Self.guestAgentInstallerPath else { return false }
        return (instance.configuration.removableMedia ?? []).contains { $0.path == path }
    }

    /// Trashes any in-progress IPSW download bundle for a VM that's being deleted.
    ///
    /// The `.kernovadownload` bundle sitting next to the chosen destination
    /// holds the partial download bytes plus resume metadata. Once the VM is
    /// gone the bundle is meaningless, so it's discarded unconditionally on
    /// delete (not gated on the "delete externals" toggle), using the same
    /// disposition as the VM itself — `permanently` removes it immediately
    /// instead of trashing it so an immediate delete leaves nothing behind. The
    /// completed IPSW file at `downloadDestinationPath`, if present, lives at a
    /// user-known path and is intentionally left alone. No-op for VMs without a
    /// `.downloadLatest` install context.
    private func cleanupInstallResumeData(for instance: VMInstance, permanently: Bool) {
        guard let context = instance.configuration.installContext,
            context.source == .downloadLatest,
            let destinationURL = context.downloadDestinationURL
        else { return }
        lifecycle.ipswService.discardResumeData(at: destinationURL, permanently: permanently)
        Self.logger.notice(
            "Discarded in-progress download bundle for deleted VM '\(instance.name, privacy: .public)'"
        )
    }

    /// Detached delete for a single external attachment, to Trash or
    /// immediately depending on `permanently`.
    ///
    /// Mirrors the error policy of `removeStorageDisk` / `removeRemovableMedia`:
    /// missing files are swallowed at `.notice` (the source may have been
    /// moved or deleted out-of-band), other failures log `.warning` and
    /// surface a single error alert on the MainActor.
    private func deleteExternalAttachment(
        at url: URL, label: String, vmName: String, permanently: Bool
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if permanently {
                    // RATIONALE: the user-confirmed "Delete Immediately" path; the deliberate
                    // exception to CLAUDE.md's "prefer trash over rm" guideline (see also
                    // `VMStorageService.permanentlyDeleteVMBundle`).
                    try FileManager.default.removeItem(at: url)
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
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

    // MARK: - Import

    /// Imports a `.kernova` VM bundle from an external location (Finder double-click, drag-and-drop).
    ///
    /// If the bundle is already inside the VMs directory, it is simply selected.
    /// If a VM with the same UUID already exists in the library, that instance is selected.
    /// Otherwise, the bundle is copied into the VMs directory asynchronously with a phantom row.
    func importVM(from sourceURL: URL) {
        do {
            let vmsDir = try storageService.vmsDirectory

            // If the source is already inside our VMs directory, just select it
            if sourceURL.path(percentEncoded: false).hasPrefix(vmsDir.path(percentEncoded: false)) {
                let config = try storageService.loadConfiguration(from: sourceURL)
                if let existing = instances.first(where: { $0.id == config.id }) {
                    selectedID = existing.id
                    return
                }
            }

            // Load config from the source to check for duplicate UUIDs
            let config = try storageService.loadConfiguration(from: sourceURL)

            if let existing = instances.first(where: { $0.id == config.id }) {
                selectedID = existing.id
                Self.logger.info(
                    "VM '\(config.name, privacy: .public)' already in library — selected existing instance")
                return
            }

            // Serialize: only one preparing operation at a time
            guard !hasPreparing else {
                Self.logger.info("Import blocked: another preparing operation is in progress")
                presentError(PreparingError.operationInProgress)
                return
            }

            // Check save file from source bundle (destination doesn't exist yet)
            let sourceLayout = VMBundleLayout(bundleURL: sourceURL)
            let initialStatus = Self.initialStatus(for: config, layout: sourceLayout)

            // Determine destination, avoiding filename collisions
            let destinationURL: URL = {
                let candidate = vmsDir.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
                guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) else {
                    return candidate
                }
                let stem = sourceURL.deletingPathExtension().lastPathComponent
                let ext = sourceURL.pathExtension
                var counter = 2
                var url: URL
                repeat {
                    url = vmsDir.appendingPathComponent("\(stem) \(counter).\(ext)", isDirectory: true)
                    counter += 1
                } while FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                return url
            }()
            // Create phantom row immediately
            let phantom = VMInstance(configuration: config, bundleURL: destinationURL, status: initialStatus)
            wirePersistence(for: phantom)
            instances.append(phantom)
            sortInstances()
            persistOrder()
            selectedID = phantom.id

            // Launch async file copy and assign preparing state atomically
            let task = Task { [weak self] in
                do {
                    try await Task.detached {
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    }.value

                    // Clear preparing state regardless of whether the view model is still alive —
                    // the phantom row's UI should always reflect completion.
                    phantom.preparingState = nil
                    guard self != nil else {
                        Self.logger.warning(
                            "Import completed but view model was deallocated — VM '\(config.name, privacy: .public)' exists on disk but was not added to library"
                        )
                        return
                    }
                    Self.logger.notice(
                        "Imported VM '\(config.name, privacy: .public)' from \(sourceURL.lastPathComponent, privacy: .public)"
                    )
                } catch {
                    guard let self else {
                        // Clear preparing state and trash partial bundle even without the view model.
                        phantom.preparingState = nil
                        Self.trashPartialBundle(at: phantom.bundleURL)
                        Self.logger.error(
                            "Import failed and view model was deallocated — trashed partial bundle '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                        )
                        return
                    }
                    self.cleanupPhantomInstance(phantom)
                    if !Task.isCancelled {
                        Self.logger.error(
                            "Failed to import VM '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                        )
                        self.presentError(error)
                    }
                }
            }
            phantom.preparingState = VMInstance.PreparingState(operation: .importing, task: task)
        } catch {
            Self.logger.error(
                "Failed to import VM from \(sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
        }
    }

    // MARK: - Rename

    enum RenameTarget: Equatable {
        case sidebar(UUID)
        case detail(UUID)
    }

    /// One of the two inline-rename surfaces, without the instance baked in.
    ///
    /// Commit/cancel call sites pass the surface and the instance separately so
    /// an instance/target id mismatch is unrepresentable; the view model pairs
    /// them into a ``RenameTarget`` itself.
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
    /// The marker is only cleared while it still belongs to `surface`'s rename
    /// of `instance`: a commit can fire from a field editor resigning *because*
    /// a rename just started on the other surface (its `makeFirstResponder`
    /// synchronously ends the pending session mid-handoff), and clearing
    /// unconditionally would wipe the newer rename's marker before its UI ever
    /// opened.
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

    /// Cancels the rename that `surface` has open on `instance`.
    ///
    /// A rename that has since moved to the other surface is left untouched
    /// (see ``commitRename(for:newName:from:)``).
    func cancelRename(for instance: VMInstance, from surface: RenameSurface) {
        clearRename(ifOwnedBy: surface.target(for: instance))
    }

    /// The single ownership rule shared by commit and cancel: the marker is
    /// cleared only while it still points at the surface that is ending.
    private func clearRename(ifOwnedBy target: RenameTarget) {
        if activeRename == target {
            activeRename = nil
        }
    }

    // MARK: - Save Configuration

    func saveConfiguration(for instance: VMInstance) {
        do {
            try storageService.saveConfiguration(instance.configuration, to: instance.bundleURL)
        } catch {
            Self.logger.error(
                "Failed to save configuration for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
        }
    }

    /// Wires `instance.onUpdateConfiguration` so guest-driven mutations
    /// (e.g. the guest reporting a new agent version via `Hello`, or the
    /// post-start watchdog clearing the install-nudge dismissal) flow
    /// through the centralized `updateConfiguration` dispatcher.
    ///
    /// Called at every `VMInstance` construction site in this view model.
    private func wirePersistence(for instance: VMInstance) {
        // Both closures are stored *on* `instance`, so they capture it weakly:
        // a strong capture forms a self-retain cycle that leaks the VMInstance
        // after it's removed from `instances`. Each only ever fires through the
        // instance (e.g. `performConfigurationMutation`, the vsock handshake),
        // so the weak ref is always live at call time.
        instance.onUpdateConfiguration = { [weak self, weak instance] mutate in
            guard let self, let instance else { return }
            self.updateConfiguration(of: instance, mutate: mutate)
        }
        // Auto-eject the installer disk once the agent handshakes a current
        // version (install/update complete). Centralized here so it fires
        // regardless of which window is open — replacing the former
        // clipboard-window-bound auto-eject.
        instance.onAgentBecameCurrent = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.unmountGuestAgentInstaller(from: instance)
        }
    }

    /// The single entry point for any UI-driven or programmatic mutation of
    /// `instance.configuration`.
    ///
    /// Applies the mutation, persists the result, and dispatches the live
    /// policy / removable-media reconcile. No-ops when the mutation produces
    /// the same value, so calls that don't actually change anything are
    /// free.
    ///
    /// All settings-view bindings, the guest-agent installer mount/unmount,
    /// storage-disk add/remove, display-window window-state writes, and
    /// guest-driven mutations (via `instance.onUpdateConfiguration`) route
    /// through here, so there is exactly one place where the "config
    /// changed" side effects fire. For mutations to fields that don't
    /// affect live policy (e.g. `displayPreference`, `lastSeenAgentVersion`),
    /// the `applyLivePolicy` call returns early — there is no overhead beyond
    /// the dispatch check.
    func updateConfiguration(
        of instance: VMInstance,
        mutate: (inout VMConfiguration) -> Void
    ) {
        let old = instance.configuration
        var new = old
        mutate(&new)
        guard new != old else { return }
        instance.configuration = new
        saveConfiguration(for: instance)
        applyLivePolicy(for: instance, old: old, new: new)
    }

    /// Pushes a configuration change to a running VM.
    ///
    /// Hot-toggleable fields (`agentLogForwardingEnabled`,
    /// `clipboardSharingEnabled`) take effect immediately via
    /// `VMInstance.applyLivePolicy`; changes to `removableMedia` trigger
    /// a runtime XHCI list-diff via `applyLiveRemovableMediaChange`;
    /// everything else is persisted-only and waits for next start.
    ///
    /// Called from `updateConfiguration` after the new value has been
    /// written to `instance.configuration` and persisted to disk.
    func applyLivePolicy(for instance: VMInstance, old: VMConfiguration, new: VMConfiguration) {
        instance.applyLivePolicy(oldConfig: old, newConfig: new)

        let mediaChanged = VMConfiguration.removableMediaChanged(old: old, new: new)
        // Only dispatch when running/paused — stopped VMs persist the new
        // media list and pick it up on next start. The lifecycle layer
        // surfaces a noVirtualMachine error if status is running but no live
        // VZ machine is present (rare race during teardown), so we don't
        // duplicate that guard here.
        guard mediaChanged, instance.status == .running || instance.status == .paused else { return }

        // Record the latest target and start a reconciliation Task if one
        // isn't already draining. The Task loops until
        // `pendingRemovableMediaTarget` is empty so rapid edits converge on
        // the final state without spawning racing detach/attach pairs.
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
    /// Each pass calls `applyLiveRemovableMediaChange` to reconcile the
    /// live device list to the latest pending target. New writes that
    /// arrive during a pass (between the dictionary read at the top of the
    /// loop and the next iteration) are picked up by the next iteration so
    /// rapid edits always converge to the final user-selected state.
    private func runRemovableMediaReconciliation(for instance: VMInstance, id: UUID) async {
        defer { reconcilingRemovableMediaInstances.remove(id) }
        while let target = pendingRemovableMediaTarget.removeValue(forKey: id) {
            // If the VM stopped (or transitioned out of a hot-pluggable state)
            // while we were awaiting the previous pass, abandon reconciliation:
            // the stopped VM picks up the latest config on next start, and
            // hitting XHCI on a torn-down VM would surface a spurious
            // `noVirtualMachine` error to the user.
            guard instance.status == .running || instance.status == .paused else { break }
            await applyLiveRemovableMediaChange(for: instance, target: target)
        }
    }

    /// Reconciles the live removable media list with `target`.
    ///
    /// Performs a per-id diff against `instance.liveRemovableMedia`:
    /// - present in tracking but not target → detach
    /// - present in target but not tracking → attach
    /// - present in both with changed `path` or `readOnly` → detach + reattach
    ///
    /// On unexpected detach or attach errors, the persisted config is
    /// rolled back to match `instance.liveRemovableMedia` so the UI snaps
    /// to what is actually attached and the user sees an alert describing
    /// the failure. `deviceNotFound` and `noVirtualMachine` errors are
    /// handled as confirmed-gone / silent bail respectively (this is also
    /// what covers the case where the user ejected the disk from inside
    /// the guest).
    private func applyLiveRemovableMediaChange(
        for instance: VMInstance,
        target: [RemovableMediaItem]
    ) async {
        let tracked = instance.liveRemovableMedia
        // Tolerate duplicate ids defensively — a hand-edited or corrupted
        // config.json could in theory ship two `removableMedia` entries with
        // the same UUID. Crashing here would take the host app down; instead,
        // keep the first occurrence so the reconcile can still make progress.
        let targetByID = Dictionary(target.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let trackedByID = Dictionary(tracked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Lookup table used by the rollback path so a failed reconcile can
        // rebuild `config.removableMedia` from whatever is still in live
        // tracking. Tracked entries win over target entries on id collisions
        // so a mutated row that failed mid-swap restores its original
        // path/readOnly; new ids only present in target supply metadata
        // for successful attaches.
        var rollbackLookup: [UUID: RemovableMediaItem] = [:]
        for info in tracked {
            rollbackLookup[info.id] = RemovableMediaItem(
                id: info.id, path: info.path, readOnly: info.readOnly)
        }
        for item in target where rollbackLookup[item.id] == nil {
            rollbackLookup[item.id] = item
        }

        // Classify each id by what action it needs.
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
            } catch USBDeviceError.noVirtualMachine {
                Self.logger.notice(
                    "VM '\(instance.name, privacy: .public)' torn down during media detach; abandoning reconcile"
                )
                return
            } catch USBDeviceError.deviceNotFound {
                // Guest ejected this item (or it was never attached). The
                // lifecycle layer's `removeAll` is skipped when the framework
                // call throws, so clear stale tracking explicitly to keep
                // the host model converged with reality.
                Self.logger.notice(
                    "Removable media '\(device.displayName, privacy: .public)' was already gone on '\(instance.name, privacy: .public)' (deviceNotFound); clearing tracking"
                )
                instance.liveRemovableMedia.removeAll { $0.id == device.id }
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
                _ = try await lifecycle.attachUSBDevice(
                    diskImagePath: item.path,
                    readOnly: item.readOnly,
                    desiredUUID: item.id,
                    to: instance
                )
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
    /// Called from the reconcile error paths so the user sees an alert
    /// AND a UI that matches reality, rather than a persisted config
    /// describing devices the framework refused to attach (or refused to
    /// detach). The write bypasses `updateConfiguration` to avoid
    /// re-entering the reconcile pipeline — we want to land on the
    /// rolled-back state, not retry it.
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

    // MARK: - Guest Agent Installer

    /// Mounts the bundled `KernovaGuestAgent.dmg` as a read-only USB device so
    /// the user can run `install.command` inside the guest.
    ///
    /// Used by the
    /// clipboard window's "Install Guest Agent…" affordance, the sidebar's
    /// agent-status popover, and the menubar item.
    ///
    /// On mount (or when the disk is already mounted), asks the presenter to
    /// show an alert explaining the next step (open the disk in the guest's
    /// Finder, run install.command). The alert unifies the post-click
    /// experience across all three entry points.
    ///
    /// No-op if the bundled DMG is already present in this VM's
    /// `removableMedia` list — duplicate mounts don't help the user.
    func mountGuestAgentInstaller(
        on instance: VMInstance, purpose: GuestAgentInstallerPurpose = .install
    ) {
        guard let url = KernovaGuestAgentInfo.installerDiskImageURL else {
            Self.logger.fault("Guest agent installer DMG missing from app bundle")
            assertionFailure("KernovaGuestAgent.dmg missing — check 'Package Guest Agent DMG' build phase outputs")
            return
        }
        if isGuestAgentInstallerMounted(on: instance) {
            Self.logger.debug("Guest agent installer already mounted on '\(instance.name, privacy: .public)'")
            // Still surface the instructions — the user just clicked an
            // install/update affordance and is owed feedback even if the
            // disk happens to already be mounted from a prior click.
            presenter?.presentInstallerMounted(vmName: instance.name, purpose: purpose)
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
                        label: "Kernova Guest Agent"
                    )
                ]
        }
        presenter?.presentInstallerMounted(vmName: instance.name, purpose: purpose)
    }

    /// Marks this VM's `.waiting` install nudge as dismissed and persists the choice.
    ///
    /// The sidebar icon for `.waiting` will no longer surface; `.outdated`, `.unresponsive`, and
    /// `.expectedMissing` continue to surface (those imply something more urgent than "you could
    /// install this").
    func dismissAgentInstallNudge(for instance: VMInstance) {
        guard !instance.configuration.agentInstallNudgeDismissed else { return }
        Self.logger.notice("User dismissed install-agent nudge for '\(instance.name, privacy: .public)'")
        updateConfiguration(of: instance) { $0.agentInstallNudgeDismissed = true }
    }

    /// Removes the bundled guest agent installer entry from
    /// `removableMedia` if currently present.
    ///
    /// Identified by path equality with
    /// `KernovaGuestAgentInfo.installerDiskImageURL`. The reconcile flow
    /// performs the runtime detach. Reached three ways: the menubar item's
    /// eject mode, the user-driven "Eject" in Settings, and the post-install
    /// auto-eject wired in ``wirePersistence(for:)``.
    func unmountGuestAgentInstaller(from instance: VMInstance) {
        guard let url = KernovaGuestAgentInfo.installerDiskImageURL else { return }
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
    /// When `trashFile` is `true`, the underlying file is moved to Trash —
    /// internal (bundle-owned) disks resolve against `instance.bundleURL`,
    /// external disks resolve against their absolute path. If the file is
    /// already gone, the missing-file error is logged and swallowed so the
    /// user doesn't see an alert for a no-op cleanup.
    ///
    /// `FileManager.trashItem` is a synchronous call that can block for
    /// seconds on slow or unresponsive volumes (network shares, sleeping
    /// external drives), so the trash runs in `Task.detached` to keep the
    /// MainActor responsive. The returned Task lets tests await completion;
    /// production callers use `@discardableResult` and ignore it.
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
        // Never trash a file another VM still references. Only external disks
        // can be shared (bundle-relative paths are per-VM), so the check is
        // scoped to those. The UI hard-blocks the trash option for shared
        // disks; this enforces the same invariant at the model layer.
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
        return Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try FileManager.default.trashItem(at: diskURL, resultingItemURL: nil)
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

    /// Renames a storage disk's user-facing label, persisting through
    /// `updateConfiguration`.
    ///
    /// The label is cosmetic — it has no effect on the guest (the virtio block
    /// identifier is derived from the disk's UUID, not its label), so renaming
    /// is safe for any disk including the main disk and costs nothing on the
    /// filesystem (the backing file keeps its stable UUID name). Whitespace is
    /// trimmed and an empty result is ignored, so clearing the field doesn't
    /// blank the label. Duplicate labels are allowed on an explicit rename —
    /// only machine-generated defaults are uniqued (see
    /// `StorageDisk.uniqueLabel`).
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

    /// Renames a removable medium's user-facing label, persisting through
    /// `updateConfiguration`.
    ///
    /// Like ``renameStorageDisk(_:newLabel:on:)`` the label is purely cosmetic.
    /// It's safe to rename while the VM is running: the change persists and the
    /// live reconciliation (`applyLiveRemovableMediaChange`) only detaches/
    /// reattaches when `path` or `readOnly` differs, so a label-only edit leaves
    /// the medium mounted. Whitespace is trimmed and an empty result is ignored.
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

    /// Removes a removable media entry from the configuration.
    ///
    /// When `trashFile` is `true`, the underlying file at the item's
    /// absolute path is moved to Trash. Every removable item is a
    /// user-picked external file, so there's no bundle-relative case to
    /// disambiguate. Missing files are swallowed (`.notice` log, no error
    /// alert) because removable media are often transient — a user may
    /// have already deleted or unmounted the source. Other failures are
    /// surfaced via the error alert.
    ///
    /// Mutating `config.removableMedia` through `updateConfiguration`
    /// triggers `applyLivePolicy` → `applyLiveRemovableMediaChange`, so
    /// the hot-detach reconciliation runs automatically when the VM is
    /// running. `trashItem` succeeds even while the VM still holds the
    /// file open, so we don't need to wait for the detach to complete.
    ///
    /// The trash runs in `Task.detached` (see `removeStorageDisk` for the
    /// reasoning). The returned Task lets tests await completion;
    /// `@discardableResult` lets the UI callers ignore it.
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
        // The bundled Guest Agent installer lives inside the app bundle and is
        // app-owned: removing it only detaches the entry, never trashes the
        // file (trashing it would corrupt the bundle for every VM).
        if isGuestAgentInstaller(item) {
            Self.logger.notice(
                "Kept Guest Agent installer '\(item.label, privacy: .public)' — app-owned; removed entry only"
            )
            return nil
        }
        // Never trash a file another VM still references (the UI hard-blocks
        // the trash option for shared media; this enforces it at the model layer).
        if !sharingVMNames(forPath: item.path, excluding: instance).isEmpty {
            Self.logger.notice(
                "Kept shared media '\(item.label, privacy: .public)' — still used by another VM; removed entry only"
            )
            return nil
        }
        let url = URL(fileURLWithPath: item.path)
        let label = item.label
        let vmName = instance.name
        return Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
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
    /// The settings view uses this so the user always sees the main disk
    /// as a row, and mutating helpers fall back to it when initializing
    /// the list on first edit. Static because it depends only on the
    /// bundle layout, not on view-model state.
    static func defaultStorageDisks(for instance: VMInstance) -> [StorageDisk] {
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        return [ConfigurationBuilder.defaultMainDisk(layout: layout)]
    }

    /// Creates a new ASIF disk image inside the VM bundle and adds it to
    /// `storageDisks`.
    ///
    /// The returned Task lets tests await completion of the async create +
    /// persist; production callers use `@discardableResult` and ignore it
    /// (mirrors ``removeStorageDisk(_:from:trashFile:)``).
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

                // Bundle-relative path (`AdditionalDisks/<id>.asif`) so the
                // entry travels with the bundle on clone / move.
                let relativePath = "AdditionalDisks/\(diskID.uuidString).asif"
                // Compute the unique default label *inside* the mutate closure
                // against the live config, so two rapid creates can't both read
                // the same snapshot and pick the same "… 2" suffix.
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
                        try FileManager.default.trashItem(at: diskURL, resultingItemURL: nil)
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
    /// The backing file is **not** bundle-owned — its lifecycle is the user's
    /// responsibility. Removal from the list does not trash the file, and
    /// cloning the VM references the same path rather than duplicating it.
    func createRemovableMedia(for instance: VMInstance, sizeInGB: Int, destinationURL: URL) {
        Task {
            do {
                try await diskImageService.createDiskImage(at: destinationURL, sizeInGB: sizeInGB)

                let item = RemovableMediaItem(
                    path: destinationURL.path(percentEncoded: false),
                    readOnly: false,
                    label: destinationURL.deletingPathExtension().lastPathComponent
                )
                updateConfiguration(of: instance) { config in
                    config.removableMedia = (config.removableMedia ?? []) + [item]
                }

                Self.logger.notice(
                    "Created removable disk '\(item.label, privacy: .public)' (\(sizeInGB, privacy: .public) GB) at '\(destinationURL.path, privacy: .public)' for VM '\(instance.name, privacy: .public)'"
                )
            } catch {
                // Only attempt cleanup when the write itself failed — earlier
                // phases throw before the destination file is touched, so trashing
                // there would either be a no-op or, in the user-chosen-path case,
                // remove an unrelated pre-existing file.
                if case DiskImageError.writeFailed = error {
                    do {
                        try FileManager.default.trashItem(at: destinationURL, resultingItemURL: nil)
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

    func cloneVM(_ instance: VMInstance) {
        guard instance.status.canEditSettings else {
            Self.logger.debug(
                "Clone skipped for '\(instance.name, privacy: .public)': status '\(instance.status.displayName, privacy: .public)' does not allow editing"
            )
            return
        }
        guard !hasPreparing else {
            Self.logger.info("Clone blocked: another preparing operation is in progress")
            presentError(PreparingError.operationInProgress)
            return
        }

        let existingNames = instances.map(\.configuration.name)
        var clonedConfig = instance.configuration.clonedForNewInstance(existingNames: existingNames)

        // Regenerate platform identity fields
        clonedConfig.macAddress = VZMACAddress.randomLocallyAdministered().string

        if clonedConfig.guestOS == .macOS {
            clonedConfig.machineIdentifierData = VZMacMachineIdentifier().dataRepresentation
        }

        if clonedConfig.bootMode == .efi || clonedConfig.bootMode == .linuxKernel {
            clonedConfig.genericMachineIdentifierData = VZGenericMachineIdentifier().dataRepresentation
        }

        // Determine which bundle files to copy
        var filesToCopy = ["Disk.asif"]
        switch clonedConfig.guestOS {
        case .macOS:
            filesToCopy.append(contentsOf: ["AuxiliaryStorage", "HardwareModel"])
        case .linux:
            if clonedConfig.bootMode == .efi {
                filesToCopy.append("EFIVariableStore")
            }
        }

        // Track internal storage disks that need to be copied. The main
        // bundle disk (`Disk.asif`) lives at a fixed relative path so it
        // doesn't need remapping — only `AdditionalDisks/<id>.asif` entries
        // do, because the cloned IDs differ from the originals.
        let originalDisks = instance.configuration.storageDisks ?? []
        let clonedDisks = clonedConfig.storageDisks ?? []
        let internalDiskMapping: [(sourceID: UUID, clonedDisk: StorageDisk)] = zip(originalDisks, clonedDisks)
            .compactMap { original, cloned in
                guard cloned.isInternal, cloned.path.hasPrefix("AdditionalDisks/") else { return nil }
                return (sourceID: original.id, clonedDisk: cloned)
            }

        // Derive the destination bundle URL (may touch disk to ensure VMs directory exists)
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

        // Create phantom row immediately
        let phantom = VMInstance(configuration: clonedConfig, bundleURL: bundleURL)
        wirePersistence(for: phantom)
        instances.append(phantom)
        sortInstances()
        persistOrder()
        selectedID = phantom.id

        // Launch async file copy and assign preparing state atomically
        let sourceBundleURL = instance.bundleURL
        let config = clonedConfig
        let storage = storageService
        let diskMapping = internalDiskMapping
        let bundleFilesToCopy = filesToCopy
        let task = Task { [weak self] in
            let log = Self.logger
            do {
                let skippedDiskIDs: Set<UUID> = try await Task.detached {
                    let resultURL = try storage.cloneVMBundle(
                        from: sourceBundleURL, newConfiguration: config, filesToCopy: bundleFilesToCopy)

                    // Write regenerated MachineIdentifier file for macOS clones (off main thread)
                    if let machineIDData = config.machineIdentifierData, config.guestOS == .macOS {
                        let layout = VMBundleLayout(bundleURL: resultURL)
                        try machineIDData.write(to: layout.machineIdentifierURL, options: .atomic)
                    }

                    // Copy internal additional disk files and track any missing sources
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
                }.value

                // Remove skipped disks and remap each kept internal additional
                // disk's `path` to its regenerated id-based filename.
                // `clonedForNewInstance` gives every disk a fresh `id` (so
                // virtio/USB device identifiers don't collide with the source
                // bundle) but copies the old `path` verbatim; the file copy
                // above wrote each disk to `AdditionalDisks/<new-id>.asif`, so
                // the stored path must follow or boot-time resolution looks for
                // the source bundle's old id and fails with `storageDiskNotFound`.
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

                // Clear preparing state regardless of whether the view model is still alive —
                // the phantom row's UI should always reflect completion.
                phantom.preparingState = nil
                guard self != nil else {
                    Self.logger.warning(
                        "Clone completed but view model was deallocated — VM '\(config.name, privacy: .public)' exists on disk but was not added to library"
                    )
                    return
                }
                Self.logger.notice(
                    "Cloned VM '\(instance.name, privacy: .public)' as '\(config.name, privacy: .public)'")
            } catch {
                guard let self else {
                    // Clear preparing state and trash partial bundle even without the view model.
                    phantom.preparingState = nil
                    Self.trashPartialBundle(at: phantom.bundleURL)
                    Self.logger.error(
                        "Clone failed and view model was deallocated — trashed partial bundle '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                self.cleanupPhantomInstance(phantom)
                if !Task.isCancelled {
                    Self.logger.error(
                        "Failed to clone VM '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                    )
                    self.presentError(error)
                }
            }
        }
        phantom.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
    }

    // MARK: - Sleep/Wake

    /// Pauses all running VMs before system sleep.
    ///
    /// Tracks which VMs were auto-paused
    /// so only those are resumed on wake (preserving user-paused VMs).
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

            // Build a map of UUID → bundle URL for bundles currently on disk
            var diskConfigs: [(VMConfiguration, URL)] = []
            var failedBundles: [String] = []
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
                }
            }
            let diskIDs = Set(diskConfigs.map(\.0.id))
            let memoryIDs = Set(instances.map(\.id))

            // Additions: bundles on disk that aren't in memory
            var didChange = false
            for (config, bundleURL) in diskConfigs where !memoryIDs.contains(config.id) {
                let layout = VMBundleLayout(bundleURL: bundleURL)
                let initialStatus = Self.initialStatus(for: config, layout: layout)
                let instance = VMInstance(
                    configuration: config,
                    bundleURL: bundleURL,
                    status: initialStatus
                )
                wirePersistence(for: instance)
                instances.append(instance)
                Self.logger.info("Discovered VM '\(config.name, privacy: .public)' on disk — added to library")
                didChange = true
            }

            // Removals: instances in memory whose bundles no longer exist on disk
            // Only remove resting-state VMs — never touch running/paused/preparing ones
            let instancesToRemove = instances.filter { instance in
                !diskIDs.contains(instance.id)
                    && !instance.isPreparing
                    && (instance.status == .stopped
                        || instance.status == .error
                        || instance.status == .initialBoot)
            }
            for instance in instancesToRemove {
                // Cancel any in-flight install task before evicting — otherwise
                // the task keeps mutating an orphan instance the view model no
                // longer knows about, wasting work and potentially racing.
                instance.installTask?.cancel()
                instances.removeAll { $0.id == instance.id }
                if selectedID == instance.id {
                    selectedID = instances.first?.id
                }
                Self.logger.info("VM '\(instance.name, privacy: .public)' no longer on disk — removed from library")
                didChange = true
            }

            if didChange {
                sortInstances()
                persistOrder()
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

    // MARK: - Cancel Preparing

    func confirmCancelPreparing(_ instance: VMInstance) {
        presenter?.presentCancelPreparing(for: instance)
    }

    func cancelPreparingConfirmed(_ instance: VMInstance) {
        let operationLabel = instance.preparingState?.operation.displayLabel ?? "preparing"

        instance.preparingState?.task.cancel()
        cleanupPhantomInstance(instance)

        Self.logger.notice("Cancelled \(operationLabel, privacy: .public) for '\(instance.name, privacy: .public)'")
    }

    /// Removes a phantom instance from the library, clears its preparing state, and trashes its partial bundle.
    private func cleanupPhantomInstance(_ phantom: VMInstance) {
        instances.removeAll { $0.id == phantom.id }
        persistOrder()
        if selectedID == phantom.id {
            selectedID = instances.first?.id
        }
        phantom.preparingState = nil
        Self.trashPartialBundle(at: phantom.bundleURL)
    }

    // MARK: - Reorder

    /// Moves VMs in the sidebar list and persists the new order.
    ///
    /// Called by the sidebar outline view's drag-drop `acceptDrop`.
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

    /// Snapshots the current instance order into customOrder and persists it to UserDefaults.
    private func persistOrder() {
        customOrder = instances.map(\.id)
        UserDefaults.standard.set(customOrder.map(\.uuidString), forKey: Self.vmOrderKey)
    }

    // MARK: - Error Handling

    /// Moves a partial VM bundle to the Trash in the background, logging on failure.
    private static func trashPartialBundle(at url: URL) {
        let log = logger
        Task.detached {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                log.error(
                    "Failed to clean up partial bundle at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Error type for preparing-related validation failures.
    private enum PreparingError: LocalizedError {
        case operationInProgress

        var errorDescription: String? {
            switch self {
            case .operationInProgress:
                return "Another clone or import operation is already in progress. Please wait for it to finish."
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

    func presentError(_ error: Error) {
        surfaceError(error.localizedDescription)
    }

    /// Routes an error message to the presenter, buffering it if none is
    /// attached yet (e.g. during the initial `loadVMs()` in `init`).
    private func surfaceError(_ message: String) {
        if let presenter {
            presenter.presentError(message)
        } else {
            bufferedErrorMessages.append(message)
        }
    }
}
