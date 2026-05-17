import Foundation
import Virtualization
import os

/// Central view model managing the list of all VMs and lifecycle operations.
@MainActor
@Observable
final class VMLibraryViewModel {
    nonisolated private static let logger = Logger(subsystem: "com.kernova.app", category: "VMLibraryViewModel")
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
    var showCreationWizard = false
    var showDeleteConfirmation = false
    var showError = false
    var errorMessage: String?

    /// Drives the post-mount instructions alert.
    ///
    /// Set after a successful
    /// `mountGuestAgentInstaller(on:)` so the user gets unified guidance no
    /// matter which entry point (sidebar popover, clipboard window button, or
    /// menubar item) triggered the mount.
    var showInstallerMountedAlert = false
    var installerMountedVMName: String?

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
    var instanceToDelete: VMInstance?
    var activeRename: RenameTarget?
    var showCancelPreparingConfirmation = false
    var preparingInstanceToCancel: VMInstance?
    var showForceStopConfirmation = false
    var instanceToForceStop: VMInstance?
    var showStopPausedConfirmation = false
    var instanceToStopPaused: VMInstance?

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

    func createVM(from wizard: VMCreationViewModel) async {
        do {
            var config = wizard.buildConfiguration()

            // For macOS guests, persist the install intent so the next Start
            // can drive the install pipeline (and download resume) without
            // the wizard. Linux guests have no Kernova-managed install step.
            #if arch(arm64)
            if config.guestOS == .macOS {
                config.installContext = wizard.buildInstallContext()
            }
            #endif

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
        } catch {
            Self.logger.error("Failed to create VM: \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    // MARK: - macOS Installation

    #if arch(arm64)
    /// Drives the install pipeline for an `.initialBoot` (or `.error` with
    /// `installContext`) VM and, on success, chains an auto-boot. Non-cancel
    /// errors leave the VM in `.error` so the user sees the message; cancel
    /// returns it to `.initialBoot` for a future retry that will resume the
    /// download from the `.resumedata` sidecar if present.
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
                // installMacOS cleared installContext on success; start(_:) now
                // sees no installContext and goes down the normal boot path.
                await self.start(instance)
            } catch is CancellationError {
                instance.installState = nil
                instance.status = .initialBoot
                Self.logger.notice(
                    "Install cancelled for '\(instance.name, privacy: .public)' — VM remains in .initialBoot"
                )
            } catch {
                instance.installState = nil
                if !Task.isCancelled {
                    Self.logger.error(
                        "Install failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                    )
                    self.presentError(error)
                }
            }
        }
    }

    /// Cancels an in-progress macOS install. The VM returns to `.initialBoot`
    /// so a subsequent Start can resume (downloads pick up from the
    /// `.resumedata` sidecar at the chosen path). Bundle is preserved. For
    /// destructive removal, use the existing delete flow ("Move to Trash").
    func cancelInstallation(_ instance: VMInstance) {
        Self.logger.info("Cancelling installation for '\(instance.name, privacy: .public)'")
        instance.installTask?.cancel()
        // installAndAutoBoot's CancellationError catch handles the status
        // transition to .initialBoot and installState cleanup. Don't duplicate
        // that work here, and don't trash the bundle — non-destructive cancel.
    }
    #endif

    // MARK: - Lifecycle

    func start(_ instance: VMInstance) async {
        #if arch(arm64)
        // VMs awaiting initial boot route through the install pipeline. The
        // pipeline clears installContext on success and chains an auto-boot;
        // failure leaves .error / .initialBoot, ready for the user to retry.
        // Check by installContext (not status) so .error retries also dispatch.
        if instance.configuration.installContext != nil {
            installAndAutoBoot(instance)
            return
        }
        #endif

        if instance.configuration.displayPreference != .inline {
            onOpenDisplayWindow?(instance)
        }
        do {
            try await lifecycle.start(instance)
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
            instanceToStopPaused = instance
            showStopPausedConfirmation = true
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
        instanceToStopPaused = nil
        showStopPausedConfirmation = false
    }

    /// Force-stops a paused VM via the stop-paused confirmation sheet's "Force Stop" action.
    /// Wrapper around `forceStop` that clears the alert state, matching `deleteConfirmed`'s pattern.
    func forceStopFromPaused(_ instance: VMInstance) async {
        await forceStop(instance)
        instanceToStopPaused = nil
        showStopPausedConfirmation = false
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
        instanceToForceStop = instance
        showForceStopConfirmation = true
    }

    func forceStopConfirmed(_ instance: VMInstance) async {
        await forceStop(instance)
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

    func confirmDelete(_ instance: VMInstance) {
        instanceToDelete = instance
        showDeleteConfirmation = true
    }

    func deleteConfirmed(_ instance: VMInstance) {
        instance.tearDownSession()
        do {
            try storageService.deleteVMBundle(at: instance.bundleURL)
            lifecycle.clearActiveOperation(for: instance.id)
            sleepPausedInstanceIDs.remove(instance.id)
            instances.removeAll { $0.id == instance.id }
            persistOrder()
            if selectedID == instance.id {
                selectedID = instances.first?.id
            }
            Self.logger.notice("Moved VM '\(instance.name, privacy: .public)' to Trash")
        } catch {
            Self.logger.error(
                "Failed to delete VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
        }
        instanceToDelete = nil
        showDeleteConfirmation = false
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

    func renameVMInSidebar(_ instance: VMInstance) {
        activeRename = .sidebar(instance.id)
    }

    func renameVM(_ instance: VMInstance) {
        activeRename = .detail(instance.id)
    }

    func commitRename(for instance: VMInstance, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            activeRename = nil
            return
        }
        updateConfiguration(of: instance) { $0.name = trimmed }
        activeRename = nil
    }

    func cancelRename() {
        activeRename = nil
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
        instance.onUpdateConfiguration = { [weak self] mutate in
            self?.updateConfiguration(of: instance, mutate: mutate)
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
    /// what covers the case where the user ejected the disc from inside
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

    // MARK: - USB Device Management

    func detachUSBDevice(_ device: USBDeviceInfo, from instance: VMInstance) {
        Self.logger.debug(
            "Detaching USB device '\(device.displayName, privacy: .public)' from '\(instance.name, privacy: .public)'")
        Task {
            do {
                try await lifecycle.detachUSBDevice(device, from: instance)
            } catch {
                Self.logger.error(
                    "USB detach failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                presentError(error)
            }
        }
    }

    // MARK: - Guest Agent Installer

    /// Mounts the bundled `KernovaGuestAgent.dmg` as a read-only USB device so
    /// the user can run `install.command` inside the guest.
    ///
    /// Used by the
    /// clipboard window's "Install Guest Agent…" affordance, the sidebar's
    /// agent-status popover, and the menubar item.
    ///
    /// On successful mount, sets `installerMountedVMName` to drive an
    /// SwiftUI `.alert()` that explains the next step (open the disk in the
    /// guest's Finder, run install.command). The alert unifies the
    /// post-click experience across all three entry points.
    ///
    /// No-op if the bundled DMG is already present in this VM's
    /// `removableMedia` list — duplicate mounts don't help the user.
    func mountGuestAgentInstaller(on instance: VMInstance) {
        guard let url = KernovaGuestAgentInfo.installerDiskImageURL else {
            Self.logger.fault("Guest agent installer DMG missing from app bundle")
            assertionFailure("KernovaGuestAgent.dmg missing — check 'Package Guest Agent DMG' build phase outputs")
            return
        }
        let path = url.path(percentEncoded: false)
        let existing = instance.configuration.removableMedia ?? []
        if existing.contains(where: { $0.path == path }) {
            Self.logger.debug("Guest agent installer already mounted on '\(instance.name, privacy: .public)'")
            // Still surface the instructions — the user just clicked an
            // install/update affordance and is owed feedback even if the
            // disk happens to already be mounted from a prior click.
            installerMountedVMName = instance.name
            showInstallerMountedAlert = true
            return
        }
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
        installerMountedVMName = instance.name
        showInstallerMountedAlert = true
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
    /// performs the runtime detach.
    func unmountGuestAgentInstaller(from instance: VMInstance) {
        guard let url = KernovaGuestAgentInfo.installerDiskImageURL else { return }
        let path = url.path(percentEncoded: false)
        guard (instance.configuration.removableMedia ?? []).contains(where: { $0.path == path }) else { return }
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
                await MainActor.run {
                    guard let self else { return }
                    self.errorMessage = message
                    self.showError = true
                }
            }
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
    /// reasoning). The returned Task lets tests await completion; the
    /// SwiftUI caller uses `@discardableResult` and ignores it.
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
                await MainActor.run {
                    guard let self else { return }
                    self.errorMessage = message
                    self.showError = true
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
    func createStorageDisk(for instance: VMInstance, sizeInGB: Int) {
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        let diskID = UUID()
        let diskURL = layout.additionalDiskURL(id: diskID)

        Task {
            do {
                try FileManager.default.createDirectory(
                    at: layout.additionalDisksDirectoryURL, withIntermediateDirectories: true)

                try await diskImageService.createDiskImage(at: diskURL, sizeInGB: sizeInGB)

                // Bundle-relative path (`AdditionalDisks/<id>.asif`) so the
                // entry travels with the bundle on clone / move.
                let relativePath = "AdditionalDisks/\(diskID.uuidString).asif"
                let disk = StorageDisk(
                    id: diskID,
                    path: relativePath,
                    readOnly: false,
                    label: "\(sizeInGB) GB Disk",
                    isInternal: true,
                    kind: .virtio
                )
                updateConfiguration(of: instance) { config in
                    var disks = config.storageDisks ?? Self.defaultStorageDisks(for: instance)
                    disks.append(disk)
                    config.storageDisks = disks
                }

                Self.logger.notice(
                    "Created in-bundle storage disk '\(disk.label, privacy: .public)' (\(sizeInGB, privacy: .public) GB) for VM '\(instance.name, privacy: .public)'"
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

        #if arch(arm64)
        if clonedConfig.guestOS == .macOS {
            clonedConfig.machineIdentifierData = VZMacMachineIdentifier().dataRepresentation
        }
        #endif

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
                    #if arch(arm64)
                    if let machineIDData = config.machineIdentifierData, config.guestOS == .macOS {
                        let layout = VMBundleLayout(bundleURL: resultURL)
                        try machineIDData.write(to: layout.machineIdentifierURL, options: .atomic)
                    }
                    #endif

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

                // Remove skipped disks. Internal disk paths are
                // bundle-relative (`AdditionalDisks/<id>.asif`) so they
                // travel with the bundle and don't need remapping.
                if !diskMapping.isEmpty {
                    phantom.configuration.storageDisks = phantom.configuration.storageDisks?
                        .filter { !skippedDiskIDs.contains($0.id) }
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
        preparingInstanceToCancel = instance
        showCancelPreparingConfirmation = true
    }

    func cancelPreparingConfirmed(_ instance: VMInstance) {
        let operationLabel = instance.preparingState?.operation.displayLabel ?? "preparing"

        instance.preparingState?.task.cancel()
        cleanupPhantomInstance(instance)

        preparingInstanceToCancel = nil
        showCancelPreparingConfirmation = false

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
    /// Called by SwiftUI's onMove handler.
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
        errorMessage = error.localizedDescription
        showError = true
    }
}
