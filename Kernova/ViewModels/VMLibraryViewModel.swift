import Foundation
import Virtualization
import os

/// Central view model managing the list of all VMs and lifecycle operations.
@MainActor
@Observable
final class VMLibraryViewModel {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMLibraryViewModel")

    // MARK: - Services

    let storageService = VMStorageService()
    let virtualizationService = VirtualizationService()
    let diskImageService = DiskImageService()
    let ipswService = IPSWService()
    let installService = MacOSInstallService()

    // MARK: - State

    var instances: [VMInstance] = []
    var selectedID: UUID?
    var showCreationWizard = false
    var showDeleteConfirmation = false
    var showError = false
    var errorMessage: String?
    var instanceToDelete: VMInstance?

    // MARK: - Directory Watcher

    /// `nonisolated(unsafe)` because `DispatchSource` is not `Sendable` and we need
    /// to cancel it in `deinit` (which is nonisolated). Safe because it is only
    /// written in `startDirectoryWatcher()` (called from `init`) and read in `deinit`.
    nonisolated(unsafe) private var directorySource: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?

    var selectedInstance: VMInstance? {
        instances.first { $0.id == selectedID }
    }

    // MARK: - Initialization

    init() {
        loadVMs()
        startDirectoryWatcher()
    }

    deinit {
        directorySource?.cancel()
    }

    // MARK: - Load

    func loadVMs() {
        do {
            let bundles = try storageService.listVMBundles()
            instances = bundles.compactMap { bundleURL in
                do {
                    var config = try storageService.loadConfiguration(from: bundleURL)
                    let needsMigration = migrateConfigurationIfNeeded(&config)
                    let layout = VMBundleLayout(bundleURL: bundleURL)
                    let initialStatus: VMStatus = layout.hasSaveFile ? .paused : .stopped
                    let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: initialStatus)
                    if needsMigration {
                        try storageService.saveConfiguration(config, to: bundleURL)
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
                    await installMacOS(on: instance, wizard: wizard)
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
    private func installMacOS(on instance: VMInstance, wizard: VMCreationViewModel) async {
        do {
            let ipswURL: URL

            switch wizard.ipswSource {
            case .downloadLatest:
                // Set up two-step install state before changing status
                instance.installState = MacOSInstallState(
                    hasDownloadStep: true,
                    currentPhase: .downloading(progress: 0, bytesWritten: 0, totalBytes: 0)
                )
                instance.status = .installing

                // Download the latest IPSW
                let restoreImage = try await ipswService.fetchLatestSupportedImage()
                try await ipswService.downloadRestoreImage(
                    restoreImage,
                    to: instance.restoreImageURL
                ) { progress, bytesWritten, totalBytes in
                    instance.installState?.currentPhase = .downloading(
                        progress: progress,
                        bytesWritten: bytesWritten,
                        totalBytes: totalBytes
                    )
                }

                // Mark download complete, transition to install phase
                instance.installState?.downloadCompleted = true
                instance.installState?.currentPhase = .installing(progress: 0)
                ipswURL = instance.restoreImageURL

            case .localFile:
                guard let path = wizard.ipswPath else {
                    throw IPSWError.noDownloadURL
                }
                ipswURL = URL(fileURLWithPath: path)

                // Local file: single-step install (no download)
                instance.installState = MacOSInstallState(
                    hasDownloadStep: false,
                    currentPhase: .installing(progress: 0)
                )
                instance.status = .installing
            }

            // Run macOS installation
            try await installService.install(
                into: instance,
                restoreImageURL: ipswURL
            ) { @MainActor progress in
                instance.installState?.currentPhase = .installing(progress: progress)
            }
        } catch is CancellationError {
            Self.logger.info("macOS installation cancelled for '\(instance.name)'")
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            Self.logger.info("IPSW download cancelled for '\(instance.name)'")
        } catch {
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            presentError(error)
        }

        instance.installTask = nil
    }

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
            try await virtualizationService.start(instance)
        } catch {
            presentError(error)
        }
    }

    func stop(_ instance: VMInstance) {
        do {
            try virtualizationService.stop(instance)
        } catch {
            presentError(error)
        }
    }

    func forceStop(_ instance: VMInstance) async {
        do {
            try await virtualizationService.forceStop(instance)
        } catch {
            presentError(error)
        }
    }

    func pause(_ instance: VMInstance) async {
        do {
            try await virtualizationService.pause(instance)
        } catch {
            presentError(error)
        }
    }

    func resume(_ instance: VMInstance) async {
        do {
            try await virtualizationService.resume(instance)
        } catch {
            presentError(error)
        }
    }

    func save(_ instance: VMInstance) async {
        do {
            try await virtualizationService.save(instance)
        } catch {
            presentError(error)
        }
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

    // MARK: - Save Configuration

    func saveConfiguration(for instance: VMInstance) {
        do {
            try storageService.saveConfiguration(instance.configuration, to: instance.bundleURL)
        } catch {
            Self.logger.error("Failed to save configuration: \(error.localizedDescription)")
        }
    }

    // MARK: - Directory Watcher

    /// Watches the VMs directory for external changes (e.g., Trash restore via Finder "Put Back")
    /// and reconciles the in-memory instances array with what's on disk.
    private func startDirectoryWatcher() {
        guard let vmsDir = try? storageService.vmsDirectory else {
            Self.logger.warning("Could not resolve VMs directory for file system watcher")
            return
        }

        let fd = open(vmsDir.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.logger.warning("Could not open VMs directory for monitoring: \(vmsDir.path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleReconciliation()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        directorySource = source

        Self.logger.info("Started directory watcher on \(vmsDir.path)")
    }

    /// Debounces rapid FS events (e.g., Finder "Put Back" touches multiple files) into a
    /// single reconciliation pass after 0.5 seconds of quiet.
    private func scheduleReconciliation() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            reconcileWithDisk()
        }
    }

    /// Diffs on-disk VM bundles against in-memory instances and adds/removes as needed.
    private func reconcileWithDisk() {
        do {
            let diskBundles = try storageService.listVMBundles()

            // Build a map of UUID → bundle URL for bundles currently on disk
            var diskConfigs: [(VMConfiguration, URL)] = []
            for bundleURL in diskBundles {
                if let config = try? storageService.loadConfiguration(from: bundleURL) {
                    diskConfigs.append((config, bundleURL))
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

    private func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
        Self.logger.error("\(error.localizedDescription)")
    }
}
