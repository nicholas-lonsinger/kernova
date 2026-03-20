import Foundation
import Virtualization
import os

/// Central view model managing the list of all VMs and lifecycle operations.
@MainActor
@Observable
final class VMLibraryViewModel {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMLibraryViewModel")
    static let lastSelectedVMIDKey = "lastSelectedVMID"

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
    var instanceToDelete: VMInstance?
    var renamingInstanceID: UUID?
    var showCancelPreparingConfirmation = false
    var preparingInstanceToCancel: VMInstance?
    var showForceStopConfirmation = false
    var instanceToForceStop: VMInstance?

    /// `true` when any instance is mid-clone or mid-import.
    var hasPreparing: Bool { instances.contains(where: \.isPreparing) }

    /// Called when a VM with `prefersFullscreen` is about to start or resume,
    /// allowing the app delegate to pre-create the fullscreen window with a spinner.
    @ObservationIgnored var onEnterFullscreen: ((VMInstance) -> Void)?

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
        ipswService: any IPSWProviding = IPSWService()
    ) {
        self.storageService = storageService
        self.diskImageService = diskImageService
        self.lifecycle = VMLifecycleCoordinator(
            virtualizationService: virtualizationService,
            installService: installService,
            ipswService: ipswService
        )

        loadVMs()
        startDirectoryWatcher()
        startSleepWatcher()
    }

    // MARK: - Load

    func loadVMs() {
        do {
            let bundles = try storageService.listVMBundles()
            instances = bundles.compactMap { bundleURL in
                do {
                    let migratedURL = try storageService.migrateBundleIfNeeded(at: bundleURL)
                    var config = try storageService.loadConfiguration(from: migratedURL)
                    let needsMigration = migrateConfigurationIfNeeded(&config)
                    let layout = VMBundleLayout(bundleURL: migratedURL)
                    let initialStatus: VMStatus = layout.hasSaveFile ? .paused : .stopped
                    let instance = VMInstance(configuration: config, bundleURL: migratedURL, status: initialStatus)
                    if needsMigration {
                        try storageService.saveConfiguration(config, to: migratedURL)
                        Self.logger.info("Migrated VM '\(config.name)': persisted stable identifiers")
                    }
                    return instance
                } catch {
                    Self.logger.error("Failed to load VM from \(bundleURL.lastPathComponent): \(error.localizedDescription)")
                    return nil
                }
            }
            .sorted { $0.configuration.createdAt < $1.configuration.createdAt }

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
            Self.logger.notice("Loaded \(self.instances.count) VMs")
        } catch {
            presentError(error)
        }
    }

    /// Fills in missing stable identifiers for VMs created before these fields were persisted.
    /// Returns `true` if the configuration was modified and needs to be saved.
    private func migrateConfigurationIfNeeded(_ config: inout VMConfiguration) -> Bool {
        var migrated = false

        // Generate a stable MAC address if networking is enabled but none was persisted
        if config.networkEnabled && config.macAddress == nil {
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
            migrated = true
        }

        // Generate a stable generic machine identifier for EFI/Linux VMs
        if (config.bootMode == .efi || config.bootMode == .linuxKernel)
            && config.genericMachineIdentifierData == nil {
            config.genericMachineIdentifierData = VZGenericMachineIdentifier().dataRepresentation
            migrated = true
        }

        return migrated
    }

    // MARK: - Create

    func createVM(from wizard: VMCreationViewModel) async {
        do {
            let config = wizard.buildConfiguration()
            let bundleURL = try storageService.createVMBundle(for: config)
            let instance = VMInstance(configuration: config, bundleURL: bundleURL)

            // Create disk image
            try await diskImageService.createDiskImage(
                at: instance.diskImageURL,
                sizeInGB: config.diskSizeInGB
            )

            instances.append(instance)
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
                        presentError(error)
                    }
                }
            }
            #endif

            Self.logger.notice("Created VM '\(config.name)'")
        } catch {
            presentError(error)
        }
    }

    // MARK: - macOS Installation

    #if arch(arm64)
    /// Cancels an in-progress macOS installation, cleans up the VM bundle, and removes it from the library.
    func cancelInstallation(_ instance: VMInstance) {
        Self.logger.info("Cancelling installation for '\(instance.name)'")

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
            Self.logger.error("Failed to trash VM bundle during cancellation: \(error.localizedDescription)")
        }

        // 4. Remove from library and update selection
        instances.removeAll { $0.id == instance.id }
        if selectedID == instance.id {
            selectedID = instances.first?.id
        }

        Self.logger.notice("Installation cancelled and VM '\(instance.name)' moved to Trash")
    }
    #endif

    // MARK: - Lifecycle

    func start(_ instance: VMInstance) async {
        if instance.configuration.prefersFullscreen {
            onEnterFullscreen?(instance)
        }
        do {
            try await lifecycle.start(instance)
        } catch {
            presentError(error)
        }
    }

    func stop(_ instance: VMInstance) {
        do {
            try lifecycle.stop(instance)
        } catch {
            presentError(error)
        }
    }

    func forceStop(_ instance: VMInstance) async {
        do {
            try await lifecycle.forceStop(instance)
            Self.logger.notice("Force-stopped VM '\(instance.name)'")
        } catch {
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
            presentError(error)
        }
    }

    func resume(_ instance: VMInstance) async {
        if instance.configuration.prefersFullscreen {
            onEnterFullscreen?(instance)
        }
        do {
            try await lifecycle.resume(instance)
        } catch {
            presentError(error)
        }
    }

    func save(_ instance: VMInstance) async {
        do {
            try await lifecycle.save(instance)
        } catch {
            presentError(error)
        }
    }

    /// Saves VM state. Throws on failure (used by save-on-quit in AppDelegate).
    func trySave(_ instance: VMInstance) async throws {
        try await lifecycle.save(instance)
    }

    /// Force-stops a VM. Throws on failure (used by save-on-quit fallback in AppDelegate).
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
            if selectedID == instance.id {
                selectedID = instances.first?.id
            }
            Self.logger.notice("Moved VM '\(instance.name)' to Trash")
        } catch {
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
                Self.logger.info("VM '\(config.name)' already in library — selected existing instance")
                return
            }

            // Serialize: only one preparing operation at a time
            guard !hasPreparing else {
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
            instances.append(phantom)
            instances.sort { $0.configuration.createdAt < $1.configuration.createdAt }
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
                        Self.logger.warning("Import completed but view model was deallocated — VM '\(config.name)' exists on disk but was not added to library")
                        return
                    }
                    Self.logger.notice("Imported VM '\(config.name)' from \(sourceURL.lastPathComponent)")
                } catch {
                    guard let self else {
                        // Clear preparing state and trash partial bundle even without the view model.
                        phantom.preparingState = nil
                        Self.trashPartialBundle(at: phantom.bundleURL)
                        Self.logger.error("Import failed and view model was deallocated — trashed partial bundle '\(config.name)': \(error.localizedDescription)")
                        return
                    }
                    self.cleanupPhantomInstance(phantom)
                    if !Task.isCancelled {
                        self.presentError(error)
                    }
                }
            }
            phantom.preparingState = VMInstance.PreparingState(operation: .importing, task: task)
        } catch {
            presentError(error)
        }
    }

    // MARK: - Rename

    func renameVM(_ instance: VMInstance) {
        renamingInstanceID = instance.id
    }

    func commitRename(for instance: VMInstance, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            renamingInstanceID = nil
            return
        }
        instance.configuration.name = trimmed
        saveConfiguration(for: instance)
        renamingInstanceID = nil
    }

    func cancelRename() {
        renamingInstanceID = nil
    }

    // MARK: - Save Configuration

    func saveConfiguration(for instance: VMInstance) {
        do {
            try storageService.saveConfiguration(instance.configuration, to: instance.bundleURL)
        } catch {
            Self.logger.error("Failed to save configuration: \(error.localizedDescription)")
        }
    }

    // MARK: - Clone

    func cloneVM(_ instance: VMInstance) {
        guard instance.status.canEditSettings else { return }
        guard !hasPreparing else {
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

        // Derive the destination bundle URL (may touch disk to ensure VMs directory exists)
        let bundleURL: URL
        do {
            bundleURL = try storageService.bundleURL(for: clonedConfig)
        } catch {
            presentError(error)
            return
        }

        // Create phantom row immediately
        let phantom = VMInstance(configuration: clonedConfig, bundleURL: bundleURL)
        instances.append(phantom)
        instances.sort { $0.configuration.createdAt < $1.configuration.createdAt }
        selectedID = phantom.id

        // Launch async file copy and assign preparing state atomically
        let sourceBundleURL = instance.bundleURL
        let config = clonedConfig
        let storage = storageService
        let task = Task { [weak self] in
            do {
                try await Task.detached {
                    let resultURL = try storage.cloneVMBundle(from: sourceBundleURL, newConfiguration: config, filesToCopy: filesToCopy)

                    // Write regenerated MachineIdentifier file for macOS clones (off main thread)
                    #if arch(arm64)
                    if let machineIDData = config.machineIdentifierData, config.guestOS == .macOS {
                        let layout = VMBundleLayout(bundleURL: resultURL)
                        try machineIDData.write(to: layout.machineIdentifierURL, options: .atomic)
                    }
                    #endif
                }.value

                // Clear preparing state regardless of whether the view model is still alive —
                // the phantom row's UI should always reflect completion.
                phantom.preparingState = nil
                guard self != nil else {
                    Self.logger.warning("Clone completed but view model was deallocated — VM '\(config.name)' exists on disk but was not added to library")
                    return
                }
                Self.logger.notice("Cloned VM '\(instance.name)' as '\(config.name)'")
            } catch {
                guard let self else {
                    // Clear preparing state and trash partial bundle even without the view model.
                    phantom.preparingState = nil
                    Self.trashPartialBundle(at: phantom.bundleURL)
                    Self.logger.error("Clone failed and view model was deallocated — trashed partial bundle '\(config.name)': \(error.localizedDescription)")
                    return
                }
                self.cleanupPhantomInstance(phantom)
                if !Task.isCancelled {
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

        Self.logger.notice("System going to sleep — pausing \(runningInstances.count) running VM(s)")

        for instance in runningInstances {
            do {
                try await lifecycle.pause(instance)
                sleepPausedInstanceIDs.insert(instance.id)
                Self.logger.debug("Paused '\(instance.name)' for sleep (status: \(instance.status.displayName))")
            } catch {
                Self.logger.error("Failed to pause '\(instance.name)' for sleep: \(error.localizedDescription)")
            }
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

        Self.logger.notice("System woke up — resuming \(instancesToResume.count) sleep-paused VM(s)")

        for instance in instancesToResume {
            do {
                try await lifecycle.resume(instance)
                Self.logger.debug("Resumed '\(instance.name)' after wake (status: \(instance.status.displayName))")
            } catch {
                Self.logger.error("Failed to resume '\(instance.name)' after wake: \(error.localizedDescription)")
            }
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
        guard let vmsDir = try? storageService.vmsDirectory else {
            Self.logger.warning("Could not resolve VMs directory for file system watcher")
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
        guard !hasPreparing else { return }
        Self.logger.debug("reconcileWithDisk: starting")
        do {
            let diskBundles = try storageService.listVMBundles()

            // Build a map of UUID → bundle URL for bundles currently on disk
            var diskConfigs: [(VMConfiguration, URL)] = []
            for bundleURL in diskBundles {
                let migratedURL = (try? storageService.migrateBundleIfNeeded(at: bundleURL)) ?? bundleURL
                if let config = try? storageService.loadConfiguration(from: migratedURL) {
                    diskConfigs.append((config, migratedURL))
                }
            }
            let diskIDs = Set(diskConfigs.map(\.0.id))
            let memoryIDs = Set(instances.map(\.id))

            // Additions: bundles on disk that aren't in memory
            var didChange = false
            for (config, bundleURL) in diskConfigs where !memoryIDs.contains(config.id) {
                var mutableConfig = config
                let _ = migrateConfigurationIfNeeded(&mutableConfig)
                let layout = VMBundleLayout(bundleURL: bundleURL)
                let initialStatus: VMStatus = layout.hasSaveFile ? .paused : .stopped
                let instance = VMInstance(
                    configuration: mutableConfig,
                    bundleURL: bundleURL,
                    status: initialStatus
                )
                instances.append(instance)
                Self.logger.info("Discovered VM '\(config.name)' on disk — added to library")
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
                Self.logger.info("VM '\(instance.name)' no longer on disk — removed from library")
                didChange = true
            }

            if didChange {
                instances.sort { $0.configuration.createdAt < $1.configuration.createdAt }
            }

            Self.logger.debug("reconcileWithDisk: complete — \(self.instances.count) VM(s) in library")
        } catch {
            Self.logger.error("Directory reconciliation failed: \(error.localizedDescription)")
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

        Self.logger.notice("Cancelled \(operationLabel) for '\(instance.name)'")
    }

    /// Removes a phantom instance from the library, clears its preparing state, and trashes its partial bundle.
    private func cleanupPhantomInstance(_ phantom: VMInstance) {
        instances.removeAll { $0.id == phantom.id }
        if selectedID == phantom.id {
            selectedID = instances.first?.id
        }
        phantom.preparingState = nil
        Self.trashPartialBundle(at: phantom.bundleURL)
    }

    // MARK: - Error Handling

    /// Moves a partial VM bundle to the Trash in the background, logging on failure.
    private static func trashPartialBundle(at url: URL) {
        let log = logger
        Task.detached {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                log.warning("Failed to clean up partial bundle at \(url.lastPathComponent): \(error.localizedDescription)")
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

    func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
        Self.logger.error("\(error.localizedDescription)")
    }
}
