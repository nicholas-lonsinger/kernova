import Foundation
import Virtualization
import os

/// Central view model managing the list of all VMs and lifecycle operations.
@MainActor
@Observable
final class VMLibraryViewModel {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMLibraryViewModel")

    // MARK: - Services

    let storageService: any VMStorageProviding
    let diskImageService: any DiskImageProviding
    let lifecycle: VMLifecycleCoordinator

    // MARK: - State

    var instances: [VMInstance] = []
    var selectedID: UUID?
    var showCreationWizard = false
    var showDeleteConfirmation = false
    var showError = false
    var errorMessage: String?
    var instanceToDelete: VMInstance?
    var renamingInstanceID: UUID?
    var isCloning = false

    // MARK: - Directory Watcher

    private var directoryWatcher: VMDirectoryWatcher?

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

            Self.logger.info("Loaded \(self.instances.count) VMs")
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

            Self.logger.info("Created VM '\(config.name)'")
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

        // 2. Release VZ resources
        instance.virtualMachine = nil
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

        Self.logger.info("Installation cancelled and VM '\(instance.name)' moved to Trash")
    }
    #endif

    // MARK: - Lifecycle

    func start(_ instance: VMInstance) async {
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
        } catch {
            presentError(error)
        }
    }

    func pause(_ instance: VMInstance) async {
        do {
            try await lifecycle.pause(instance)
        } catch {
            presentError(error)
        }
    }

    func resume(_ instance: VMInstance) async {
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
        do {
            try storageService.deleteVMBundle(at: instance.bundleURL)
            instances.removeAll { $0.id == instance.id }
            if selectedID == instance.id {
                selectedID = instances.first?.id
            }
            Self.logger.info("Moved VM '\(instance.name)' to Trash")
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
    /// Otherwise, the bundle is copied into the VMs directory and loaded.
    func importVM(from sourceURL: URL) {
        do {
            let vmsDir = try storageService.vmsDirectory

            // If the source is already inside our VMs directory, just select it
            if sourceURL.path.hasPrefix(vmsDir.path) {
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

            // Copy bundle into VMs directory
            let destinationURL = vmsDir.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            // Load and add to library
            let layout = VMBundleLayout(bundleURL: destinationURL)
            let initialStatus: VMStatus = layout.hasSaveFile ? .paused : .stopped
            let instance = VMInstance(configuration: config, bundleURL: destinationURL, status: initialStatus)
            instances.append(instance)
            instances.sort { $0.configuration.createdAt < $1.configuration.createdAt }
            selectedID = instance.id
            Self.logger.info("Imported VM '\(config.name)' from \(sourceURL.lastPathComponent)")
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

    func cloneVM(_ instance: VMInstance) async {
        guard instance.status.canEditSettings else { return }

        isCloning = true
        defer { isCloning = false }

        do {
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

            // Copy files off the main thread (disk images can be large)
            let sourceBundleURL = instance.bundleURL
            let config = clonedConfig
            let storage = storageService
            let bundleURL = try await Task.detached {
                try storage.cloneVMBundle(from: sourceBundleURL, newConfiguration: config, filesToCopy: filesToCopy)
            }.value

            // Write regenerated MachineIdentifier file for macOS clones
            #if arch(arm64)
            if let machineIDData = clonedConfig.machineIdentifierData, clonedConfig.guestOS == .macOS {
                let layout = VMBundleLayout(bundleURL: bundleURL)
                try machineIDData.write(to: layout.machineIdentifierURL, options: .atomic)
            }
            #endif

            let clonedInstance = VMInstance(configuration: clonedConfig, bundleURL: bundleURL)
            instances.append(clonedInstance)
            instances.sort { $0.configuration.createdAt < $1.configuration.createdAt }
            selectedID = clonedInstance.id

            Self.logger.info("Cloned VM '\(instance.name)' as '\(clonedConfig.name)'")
        } catch {
            presentError(error)
        }
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
        guard !isCloning else { return }
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
            // Only remove stopped or errored VMs — never touch running/paused ones
            let instancesToRemove = instances.filter { instance in
                !diskIDs.contains(instance.id)
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
        } catch {
            Self.logger.error("Directory reconciliation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Error Handling

    func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
        Self.logger.error("\(error.localizedDescription)")
    }
}
