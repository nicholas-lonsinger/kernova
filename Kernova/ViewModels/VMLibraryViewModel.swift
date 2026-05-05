import Foundation
import Virtualization
import os

/// Central view model managing the list of all VMs and lifecycle operations.
@MainActor
@Observable
final class VMLibraryViewModel {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMLibraryViewModel")
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

    /// Drives the post-mount instructions alert. Set after a successful
    /// `mountGuestAgentInstaller(on:)` so the user gets unified guidance no
    /// matter which entry point (sidebar popover, clipboard window button, or
    /// menubar item) triggered the mount.
    var showInstallerMountedAlert = false
    var installerMountedVMName: String?

    /// VMs with an in-flight installer mount. Prevents rapid double-clicks
    /// from spawning two parallel attaches — the second would race the first
    /// and likely surface as a spurious "operation in progress" error alert.
    private var mountingInstanceIDs: Set<UUID> = []
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
                    let initialStatus: VMStatus = layout.hasSaveFile ? .paused : .stopped
                    let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: initialStatus)
                    wirePersistence(for: instance)
                    return instance
                } catch {
                    Self.logger.error("Failed to load VM from \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                   instances.contains(where: { $0.id == savedID }) {
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
            let config = wizard.buildConfiguration()
            let bundleURL = try storageService.createVMBundle(for: config)
            let instance = VMInstance(configuration: config, bundleURL: bundleURL)
            wirePersistence(for: instance)

            // Create disk image
            try await diskImageService.createDiskImage(
                at: instance.diskImageURL,
                sizeInGB: config.diskSizeInGB
            )

            instances.append(instance)
            persistOrder()
            selectedID = instance.id

            // For macOS guests, start installation (store task handle for cancellation support)
            #if arch(arm64)
            if config.guestOS == .macOS {
                instance.installTask = Task {
                    do {
                        try await lifecycle.installMacOS(
                            on: instance,
                            wizard: wizard,
                            storageService: storageService
                        )
                    } catch {
                        if !Task.isCancelled {
                            Self.logger.error("Failed to install macOS on '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                            presentError(error)
                        }
                    }
                }
            }
            #endif

            Self.logger.notice("Created VM '\(config.name, privacy: .public)'")
        } catch {
            Self.logger.error("Failed to create VM: \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    // MARK: - macOS Installation

    #if arch(arm64)
    /// Cancels an in-progress macOS installation, cleans up the VM bundle, and removes it from the library.
    func cancelInstallation(_ instance: VMInstance) {
        Self.logger.info("Cancelling installation for '\(instance.name, privacy: .public)'")

        // 1. Cancel the in-flight task (triggers cooperative cancellation in download/install)
        instance.installTask?.cancel()
        instance.installTask = nil

        // 2. Release VZ resources (tearDownSession clears VM, pipes, delegate adapter)
        instance.tearDownSession()
        instance.installState = nil

        // 3. Remove bundle from disk (moves to Trash)
        do {
            try storageService.deleteVMBundle(at: instance.bundleURL)
        } catch {
            Self.logger.error("Failed to trash VM bundle during cancellation: \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }

        // 4. Remove from library and update selection
        instances.removeAll { $0.id == instance.id }
        persistOrder()
        if selectedID == instance.id {
            selectedID = instances.first?.id
        }

        Self.logger.notice("Installation cancelled and VM '\(instance.name, privacy: .public)' moved to Trash")
    }
    #endif

    // MARK: - Lifecycle

    func start(_ instance: VMInstance) async {
        if instance.configuration.displayPreference != .inline {
            onOpenDisplayWindow?(instance)
        }
        do {
            try await lifecycle.start(instance)
        } catch {
            Self.logger.error("Failed to start '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
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
            Self.logger.error("Failed to stop '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    /// Resumes a paused VM then requests a graceful ACPI shutdown. Used by the
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
            Self.logger.error("Failed to resume-and-stop '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
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
            Self.logger.error("Failed to force-stop '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
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
            Self.logger.error("Failed to pause '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
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
            Self.logger.error("Failed to resume '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    func save(_ instance: VMInstance) async {
        do {
            try await lifecycle.save(instance)
        } catch {
            Self.logger.error("Failed to save '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    /// Saves VM state. Throws on failure (used by suspend-on-quit in AppDelegate).
    func trySave(_ instance: VMInstance) async throws {
        try await lifecycle.save(instance)
    }

    /// Force-stops a VM. Throws on failure (used by suspend-on-quit fallback in AppDelegate).
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
            Self.logger.error("Failed to delete VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
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
                Self.logger.info("VM '\(config.name, privacy: .public)' already in library — selected existing instance")
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
            let initialStatus: VMStatus = sourceLayout.hasSaveFile ? .paused : .stopped

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
                        Self.logger.warning("Import completed but view model was deallocated — VM '\(config.name, privacy: .public)' exists on disk but was not added to library")
                        return
                    }
                    Self.logger.notice("Imported VM '\(config.name, privacy: .public)' from \(sourceURL.lastPathComponent, privacy: .public)")
                } catch {
                    guard let self else {
                        // Clear preparing state and trash partial bundle even without the view model.
                        phantom.preparingState = nil
                        Self.trashPartialBundle(at: phantom.bundleURL)
                        Self.logger.error("Import failed and view model was deallocated — trashed partial bundle '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    self.cleanupPhantomInstance(phantom)
                    if !Task.isCancelled {
                        Self.logger.error("Failed to import VM '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                        self.presentError(error)
                    }
                }
            }
            phantom.preparingState = VMInstance.PreparingState(operation: .importing, task: task)
        } catch {
            Self.logger.error("Failed to import VM from \(sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    // MARK: - Rename

    enum RenameTarget: Equatable {
        case sidebar(UUID)
        case detail(UUID)

        var instanceID: UUID {
            switch self {
            case .sidebar(let id), .detail(let id): return id
            }
        }
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
        instance.configuration.name = trimmed
        saveConfiguration(for: instance)
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
            Self.logger.error("Failed to save configuration for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    /// Wires `instance.onConfigurationDidChange` so host-driven mutations
    /// (e.g. the guest reporting a new agent version via `Hello`) flow back
    /// through the storage abstraction. Called at every VMInstance
    /// construction site in this view model.
    private func wirePersistence(for instance: VMInstance) {
        instance.onConfigurationDidChange = { [weak self] inst in
            self?.saveConfiguration(for: inst)
        }
    }

    /// Pushes a configuration change to a running VM. Hot-toggleable fields
    /// (`agentLogForwardingEnabled`, `clipboardSharingEnabled`) take effect
    /// immediately via `VMInstance.applyLivePolicy`; everything else is
    /// persisted-only and waits for next start.
    ///
    /// Called from `VMSettingsView.onChange` after the new value has already
    /// been written to `instance.configuration` and persisted via
    /// `saveConfiguration(for:)`.
    func applyLivePolicy(for instance: VMInstance, old: VMConfiguration, new: VMConfiguration) {
        instance.applyLivePolicy(oldConfig: old, newConfig: new)
    }

    // MARK: - USB Device Management

    func attachUSBDevice(diskImagePath: String, readOnly: Bool, to instance: VMInstance) {
        Self.logger.debug("Attaching USB device '\(URL(fileURLWithPath: diskImagePath).lastPathComponent, privacy: .public)' to '\(instance.name, privacy: .public)' (readOnly: \(readOnly, privacy: .public))")
        Task {
            do {
                _ = try await lifecycle.attachUSBDevice(
                    diskImagePath: diskImagePath,
                    readOnly: readOnly,
                    to: instance
                )
            } catch {
                Self.logger.error("USB attach failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                presentError(error)
            }
        }
    }

    func detachUSBDevice(_ device: USBDeviceInfo, from instance: VMInstance) {
        Self.logger.debug("Detaching USB device '\(device.displayName, privacy: .public)' from '\(instance.name, privacy: .public)'")
        Task {
            do {
                try await lifecycle.detachUSBDevice(device, from: instance)
            } catch {
                Self.logger.error("USB detach failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                presentError(error)
            }
        }
    }

    // MARK: - Guest Agent Installer

    /// Mounts the bundled `KernovaGuestAgent.dmg` as a read-only USB device so
    /// the user can run `install.command` inside the guest. Used by the
    /// clipboard window's "Install Guest Agent…" affordance, the sidebar's
    /// agent-status popover, and the menubar item.
    ///
    /// On successful mount, sets `installerMountedVMName` to drive an
    /// SwiftUI `.alert()` that explains the next step (open the disk in the
    /// guest's Finder, run install.command). The alert unifies the
    /// post-click experience across all three entry points.
    ///
    /// No-op if a device already mounted at the bundled DMG path is present —
    /// duplicate mounts don't help the user.
    func mountGuestAgentInstaller(on instance: VMInstance) {
        let id = instance.instanceID
        // Coalesce rapid double-clicks: if a mount Task is already in flight
        // for this VM, ignore the new click. Prevents the second attach from
        // racing the first and surfacing as a spurious error alert.
        guard !mountingInstanceIDs.contains(id) else {
            Self.logger.debug("Mount already in flight for '\(instance.name, privacy: .public)' — ignoring duplicate click")
            return
        }
        guard let url = KernovaGuestAgentInfo.installerDiskImageURL else {
            Self.logger.fault("Guest agent installer DMG missing from app bundle")
            assertionFailure("KernovaGuestAgent.dmg missing — check 'Package Guest Agent DMG' build phase outputs")
            return
        }
        let path = url.path
        if instance.attachedUSBDevices.contains(where: { $0.path == path }) {
            Self.logger.debug("Guest agent installer already mounted on '\(instance.name, privacy: .public)'")
            // Still surface the instructions — the user just clicked an
            // install/update affordance and is owed feedback even if the
            // disk happens to already be mounted from a prior click.
            installerMountedVMName = instance.name
            showInstallerMountedAlert = true
            return
        }
        Self.logger.notice("Mounting guest agent installer on '\(instance.name, privacy: .public)'")
        let vmName = instance.name
        mountingInstanceIDs.insert(id)
        Task { [weak self] in
            do {
                _ = try await self?.lifecycle.attachUSBDevice(
                    diskImagePath: path,
                    readOnly: true,
                    to: instance
                )
                self?.installerMountedVMName = vmName
                self?.showInstallerMountedAlert = true
            } catch {
                Self.logger.error("USB attach failed for '\(vmName, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                self?.presentError(error)
            }
            self?.mountingInstanceIDs.remove(id)
        }
    }

    /// Marks this VM's `.waiting` install nudge as dismissed and persists
    /// the choice. The sidebar icon for `.waiting` will no longer surface;
    /// `.outdated`, `.unresponsive`, and `.expectedMissing` continue to
    /// surface (those imply something more urgent than "you could install
    /// this").
    func dismissAgentInstallNudge(for instance: VMInstance) {
        guard !instance.configuration.agentInstallNudgeDismissed else { return }
        Self.logger.notice("User dismissed install-agent nudge for '\(instance.name, privacy: .public)'")
        instance.configuration.agentInstallNudgeDismissed = true
        saveConfiguration(for: instance)
    }

    /// Detaches the bundled guest agent installer if currently mounted.
    /// Identified by path equality with `KernovaGuestAgentInfo.installerDiskImageURL`.
    func unmountGuestAgentInstaller(from instance: VMInstance) {
        guard let url = KernovaGuestAgentInfo.installerDiskImageURL else { return }
        let path = url.path
        guard let device = instance.attachedUSBDevices.first(where: { $0.path == path }) else { return }
        Self.logger.notice("Unmounting guest agent installer from '\(instance.name, privacy: .public)'")
        detachUSBDevice(device, from: instance)
    }

    // MARK: - Additional Disks

    /// Removes an additional disk from the configuration and trashes the file if internal.
    func removeAdditionalDisk(_ disk: AdditionalDisk, from instance: VMInstance) {
        instance.configuration.additionalDisks?.removeAll { $0.id == disk.id }
        if instance.configuration.additionalDisks?.isEmpty == true {
            instance.configuration.additionalDisks = nil
        }
        saveConfiguration(for: instance)

        if disk.isInternal {
            let layout = VMBundleLayout(bundleURL: instance.bundleURL)
            let diskURL = layout.additionalDiskURL(id: disk.id)
            do {
                try FileManager.default.trashItem(at: diskURL, resultingItemURL: nil)
                Self.logger.notice("Trashed internal disk '\(disk.label, privacy: .public)' for VM '\(instance.name, privacy: .public)'")
            } catch {
                Self.logger.warning("Failed to trash internal disk '\(disk.label, privacy: .public)' at '\(diskURL.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                presentError(error)
            }
        }
    }

    /// Creates a new ASIF disk image inside the VM bundle and adds it to the configuration.
    func createAdditionalDisk(for instance: VMInstance, sizeInGB: Int) {
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        let diskID = UUID()
        let diskURL = layout.additionalDiskURL(id: diskID)

        Task {
            do {
                try FileManager.default.createDirectory(at: layout.additionalDisksDirectoryURL, withIntermediateDirectories: true)

                try await diskImageService.createDiskImage(at: diskURL, sizeInGB: sizeInGB)

                let disk = AdditionalDisk(
                    id: diskID,
                    path: diskURL.path(percentEncoded: false),
                    readOnly: false,
                    label: "\(sizeInGB) GB Disk",
                    isInternal: true
                )
                var disks = instance.configuration.additionalDisks ?? []
                disks.append(disk)
                instance.configuration.additionalDisks = disks
                saveConfiguration(for: instance)

                Self.logger.notice("Created in-bundle additional disk '\(disk.label, privacy: .public)' (\(sizeInGB, privacy: .public) GB) for VM '\(instance.name, privacy: .public)'")
            } catch {
                // Clean up the disk file if it was created before the failure
                do {
                    try FileManager.default.trashItem(at: diskURL, resultingItemURL: nil)
                } catch let cleanupError {
                    Self.logger.warning("Failed to clean up partial disk image at '\(diskURL.lastPathComponent, privacy: .public)': \(cleanupError.localizedDescription, privacy: .public)")
                }
                Self.logger.error("Failed to create additional disk for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                presentError(error)
            }
        }
    }

    // MARK: - Clone

    func cloneVM(_ instance: VMInstance) {
        guard instance.status.canEditSettings else {
            Self.logger.debug("Clone skipped for '\(instance.name, privacy: .public)': status '\(instance.status.displayName, privacy: .public)' does not allow editing")
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

        // Track internal additional disks that need to be copied and remapped
        let originalDisks = instance.configuration.additionalDisks ?? []
        let clonedDisks = clonedConfig.additionalDisks ?? []
        let internalDiskMapping: [(sourceID: UUID, clonedDisk: AdditionalDisk)] = zip(originalDisks, clonedDisks)
            .compactMap { original, cloned in
                guard cloned.isInternal else { return nil }
                return (sourceID: original.id, clonedDisk: cloned)
            }

        // Derive the destination bundle URL (may touch disk to ensure VMs directory exists)
        let bundleURL: URL
        do {
            bundleURL = try storageService.bundleURL(for: clonedConfig)
        } catch {
            Self.logger.error("Failed to derive bundle URL for clone of '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
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
                    let resultURL = try storage.cloneVMBundle(from: sourceBundleURL, newConfiguration: config, filesToCopy: bundleFilesToCopy)

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
                        try fm.createDirectory(at: destLayout.additionalDisksDirectoryURL, withIntermediateDirectories: true)
                        for mapping in diskMapping {
                            let sourceFile = sourceLayout.additionalDiskURL(id: mapping.sourceID)
                            let destFile = destLayout.additionalDiskURL(id: mapping.clonedDisk.id)
                            if fm.fileExists(atPath: sourceFile.path(percentEncoded: false)) {
                                try fm.copyItem(at: sourceFile, to: destFile)
                            } else {
                                log.warning("Internal disk '\(mapping.clonedDisk.label, privacy: .public)' source file missing at '\(sourceFile.lastPathComponent, privacy: .public)' — removing from clone")
                                skipped.insert(mapping.clonedDisk.id)
                            }
                        }
                    }
                    return skipped
                }.value

                // Remove skipped disks and remap internal disk paths to the new bundle location
                if !diskMapping.isEmpty {
                    let newLayout = VMBundleLayout(bundleURL: phantom.bundleURL)
                    phantom.configuration.additionalDisks = phantom.configuration.additionalDisks?
                        .filter { !skippedDiskIDs.contains($0.id) }
                        .map { disk in
                            guard disk.isInternal else { return disk }
                            var updated = disk
                            updated.path = newLayout.additionalDiskURL(id: disk.id).path(percentEncoded: false)
                            return updated
                        }
                    if phantom.configuration.additionalDisks?.isEmpty == true {
                        phantom.configuration.additionalDisks = nil
                    }
                    try storage.saveConfiguration(phantom.configuration, to: phantom.bundleURL)
                }

                // Clear preparing state regardless of whether the view model is still alive —
                // the phantom row's UI should always reflect completion.
                phantom.preparingState = nil
                guard self != nil else {
                    Self.logger.warning("Clone completed but view model was deallocated — VM '\(config.name, privacy: .public)' exists on disk but was not added to library")
                    return
                }
                Self.logger.notice("Cloned VM '\(instance.name, privacy: .public)' as '\(config.name, privacy: .public)'")
            } catch {
                guard let self else {
                    // Clear preparing state and trash partial bundle even without the view model.
                    phantom.preparingState = nil
                    Self.trashPartialBundle(at: phantom.bundleURL)
                    Self.logger.error("Clone failed and view model was deallocated — trashed partial bundle '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                    return
                }
                self.cleanupPhantomInstance(phantom)
                if !Task.isCancelled {
                    Self.logger.error("Failed to clone VM '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                    self.presentError(error)
                }
            }
        }
        phantom.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
    }

    // MARK: - Sleep/Wake

    /// Pauses all running VMs before system sleep. Tracks which VMs were auto-paused
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
                Self.logger.debug("Paused '\(instance.name, privacy: .public)' for sleep (status: \(instance.status.displayName, privacy: .public))")
            } catch {
                Self.logger.error("Failed to pause '\(instance.name, privacy: .public)' for sleep: \(error.localizedDescription, privacy: .public)")
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
                Self.logger.debug("Resumed '\(instance.name, privacy: .public)' after wake (status: \(instance.status.displayName, privacy: .public))")
            } catch {
                Self.logger.error("Failed to resume '\(instance.name, privacy: .public)' after wake: \(error.localizedDescription, privacy: .public)")
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
            Self.logger.warning("Could not resolve VMs directory for file system watcher: \(error.localizedDescription, privacy: .public)")
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
                    Self.logger.error("Failed to load config from \(bundleURL.lastPathComponent, privacy: .public) during reconciliation: \(error.localizedDescription, privacy: .public)")
                    failedBundles.append(bundleName)
                }
            }
            let diskIDs = Set(diskConfigs.map(\.0.id))
            let memoryIDs = Set(instances.map(\.id))

            // Additions: bundles on disk that aren't in memory
            var didChange = false
            for (config, bundleURL) in diskConfigs where !memoryIDs.contains(config.id) {
                let layout = VMBundleLayout(bundleURL: bundleURL)
                let initialStatus: VMStatus = layout.hasSaveFile ? .paused : .stopped
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
            // Only remove stopped or errored VMs — never touch running/paused/preparing ones
            let instancesToRemove = instances.filter { instance in
                !diskIDs.contains(instance.id)
                    && !instance.isPreparing
                    && (instance.status == .stopped || instance.status == .error)
            }
            for instance in instancesToRemove {
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
                Self.logger.debug("reconcileWithDisk: suppressed \(suppressedCount, privacy: .public) already-reported bundle failure(s)")
            }
            if !newFailures.isEmpty {
                reportedFailedBundles.formUnion(newFailures)
                presentError(LoadError.bundleLoadFailed(names: newFailures))
            }

            // Prune names of bundles no longer on disk so a new bundle with the same name
            // is not silently suppressed.
            let currentDiskNames = Set(diskBundles.map { $0.deletingPathExtension().lastPathComponent })
            reportedFailedBundles.formIntersection(currentDiskNames)

            Self.logger.debug("reconcileWithDisk: complete — \(self.instances.count, privacy: .public) VM(s) in library")
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

    /// Moves VMs in the sidebar list and persists the new order. Called by SwiftUI's onMove handler.
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
                log.error("Failed to clean up partial bundle at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                return "Failed to load the following VMs: \(names.joined(separator: ", ")). They may have corrupted configurations."
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
                return "Failed to pause the following VMs before sleep: \(vmNames.joined(separator: ", ")). They may experience data corruption."
            case .resumeFailed(let vmNames):
                assert(!vmNames.isEmpty, "resumeFailed requires at least one VM name")
                return "Failed to resume the following VMs after wake: \(vmNames.joined(separator: ", ")). You may need to restart them manually."
            }
        }
    }

    func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}
