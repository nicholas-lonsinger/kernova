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

    var selectedInstance: VMInstance? {
        instances.first { $0.id == selectedID }
    }

    // MARK: - Initialization

    init() {
        loadVMs()
    }

    // MARK: - Load

    func loadVMs() {
        do {
            let bundles = try storageService.listVMBundles()
            instances = bundles.compactMap { bundleURL in
                do {
                    var config = try storageService.loadConfiguration(from: bundleURL)
                    let needsMigration = migrateConfigurationIfNeeded(&config)
                    let saveFileURL = bundleURL.appendingPathComponent("SaveFile.vzvmsave")
                    let initialStatus: VMStatus = FileManager.default.fileExists(
                        atPath: saveFileURL.path
                    ) ? .paused : .stopped
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

            // For macOS guests, start installation (fire-and-forget so wizard can dismiss)
            #if arch(arm64)
            if config.guestOS == .macOS {
                Task {
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
            instance.status = .installing
            instance.installStatusDetail = "Fetching restore image info…"
            let ipswURL: URL

            switch wizard.ipswSource {
            case .downloadLatest:
                // Download the latest IPSW
                let restoreImage = try await ipswService.fetchLatestSupportedImage()
                try await ipswService.downloadRestoreImage(
                    restoreImage,
                    to: instance.restoreImageURL
                ) { progress, bytesWritten, totalBytes in
                    instance.installProgress = progress * 0.3 // First 30% is download
                    let written = Self.formatBytes(bytesWritten)
                    let total = Self.formatBytes(totalBytes)
                    instance.installStatusDetail = "Downloading macOS Image: \(written) / \(total)"
                }
                ipswURL = instance.restoreImageURL

            case .localFile:
                if let path = wizard.ipswPath {
                    ipswURL = URL(fileURLWithPath: path)
                } else {
                    throw IPSWError.noDownloadURL
                }
                instance.installProgress = 0.3
                instance.installStatusDetail = "Installing macOS…"
            }

            // Run macOS installation
            instance.installStatusDetail = "Installing macOS…"
            try await installService.install(
                into: instance,
                restoreImageURL: ipswURL
            ) { @MainActor progress in
                instance.installProgress = 0.3 + (progress * 0.7) // Last 70% is install
                instance.installStatusDetail = "Installing macOS: \(Int(progress * 100))%"
            }
        } catch {
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            presentError(error)
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
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
            Self.logger.info("Deleted VM '\(instance.name)'")
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

    // MARK: - Error Handling

    private func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
        Self.logger.error("\(error.localizedDescription)")
    }
}
