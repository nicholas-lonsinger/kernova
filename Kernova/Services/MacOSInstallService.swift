import Foundation
import Virtualization
import os

/// Manages macOS guest installation using `VZMacOSInstaller`.
///
/// Handles the full installation pipeline:
/// 1. Load restore image and extract hardware model
/// 2. Create platform configuration (auxiliary storage, hardware model, machine identifier)
/// 3. Build VZ configuration and create the virtual machine
/// 4. Run the installer with progress tracking via KVO
@MainActor
final class MacOSInstallService {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "MacOSInstallService")

    private let configBuilder = ConfigurationBuilder()
    private let storageService = VMStorageService()
    private var progressObservation: NSKeyValueObservation?

    // MARK: - Installation

    #if arch(arm64)
    /// Installs macOS from a restore image into the given VM instance.
    ///
    /// - Parameters:
    ///   - instance: The VM instance to install into.
    ///   - restoreImageURL: The local URL of the IPSW file.
    ///   - progressHandler: Called with installation progress (0.0–1.0).
    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        instance.status = .installing

        Self.logger.info("Starting macOS installation for '\(instance.name, privacy: .public)'")

        // 1. Load restore image
        let restoreImage = try await loadRestoreImage(from: restoreImageURL)

        guard let supportedConfig = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw MacOSInstallError.unsupportedRestoreImage
        }

        guard supportedConfig.hardwareModel.isSupported else {
            throw MacOSInstallError.unsupportedHardwareModel
        }

        // 2. Set up platform configuration
        try setupPlatformFiles(
            for: instance,
            hardwareModel: supportedConfig.hardwareModel
        )

        // 3. Update the VM configuration with hardware model data
        instance.configuration.hardwareModelData = supportedConfig.hardwareModel.dataRepresentation

        let machineIDURL = instance.machineIdentifierURL
        let machineIDData = try Data(contentsOf: machineIDURL)
        instance.configuration.machineIdentifierData = machineIDData

        try storageService.saveConfiguration(instance.configuration, to: instance.bundleURL)

        // 4. Build VZ configuration and create VM
        let result = try configBuilder.build(
            from: instance.configuration,
            bundleURL: instance.bundleURL
        )

        instance.serialInputPipe = result.serialInputPipe
        instance.serialOutputPipe = result.serialOutputPipe
        instance.clipboardInputPipe = result.clipboardInputPipe
        instance.clipboardOutputPipe = result.clipboardOutputPipe
        let vm = instance.attachVirtualMachine(from: result.configuration)
        instance.startSerialReading()
        instance.startClipboardService()

        // 5. Check for cancellation before starting the installer
        try Task.checkCancellation()

        // 6. Run installer with progress tracking
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: restoreImageURL)

        // Observe progress via KVO
        progressObservation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                progressHandler(fraction)
            }
        }

        defer {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        // Capture progress for the @Sendable onCancel closure (VZMacOSInstaller is not Sendable)
        let installerProgress = installer.progress

        Self.logger.info("Running macOS installer...")
        try await withTaskCancellationHandler {
            try await installer.install()
        } onCancel: {
            installerProgress.cancel()
        }

        instance.resetToStopped()
        instance.installState?.currentPhase = .installing(progress: 1.0)

        Self.logger.info("macOS installation completed for '\(instance.name, privacy: .public)'")
    }

    // MARK: - Platform Setup

    /// Creates the auxiliary storage, hardware model, and machine identifier files.
    private func setupPlatformFiles(
        for instance: VMInstance,
        hardwareModel: VZMacHardwareModel
    ) throws {
        // Write hardware model
        try hardwareModel.dataRepresentation.write(to: instance.hardwareModelURL)

        // Create machine identifier
        let machineIdentifier = VZMacMachineIdentifier()
        try machineIdentifier.dataRepresentation.write(to: instance.machineIdentifierURL)

        // Create auxiliary storage
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: instance.auxiliaryStorageURL,
            hardwareModel: hardwareModel,
            options: []
        )

        Self.logger.info("Created platform files for '\(instance.name, privacy: .public)'")
    }

    // MARK: - Helpers

    private func loadRestoreImage(from url: URL) async throws -> VZMacOSRestoreImage {
        try await VZMacOSRestoreImage.image(from: url)
    }
    #endif
}

// MARK: - MacOSInstallProviding

extension MacOSInstallService: MacOSInstallProviding {}

// MARK: - Errors

enum MacOSInstallError: LocalizedError {
    case unsupportedRestoreImage
    case unsupportedHardwareModel

    var errorDescription: String? {
        switch self {
        case .unsupportedRestoreImage:
            "The restore image does not contain a supported macOS configuration."
        case .unsupportedHardwareModel:
            "The hardware model in the restore image is not supported on this machine."
        }
    }
}
