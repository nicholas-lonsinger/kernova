import Foundation
import Virtualization
import os

/// Translates a `VMConfiguration` into a `VZVirtualMachineConfiguration`.
///
/// Supports three boot paths:
/// - **macOS**: `VZMacPlatformConfiguration` + `VZMacOSBootLoader` (Apple Silicon only)
/// - **EFI**: `VZGenericPlatformConfiguration` + `VZEFIBootLoader` (Linux guests)
/// - **Linux Kernel**: `VZGenericPlatformConfiguration` + `VZLinuxBootLoader`
struct ConfigurationBuilder: Sendable {

    /// Contains the built VZ configuration along with bidirectional serial port pipes.
    struct BuildResult: @unchecked Sendable {
        let configuration: VZVirtualMachineConfiguration
        let serialInputPipe: Pipe
        let serialOutputPipe: Pipe
    }

    private static let logger = Logger(subsystem: "com.kernova.app", category: "ConfigurationBuilder")

    /// Builds a validated `VZVirtualMachineConfiguration` from the given VM configuration and bundle URL.
    func build(from config: VMConfiguration, bundleURL: URL) throws -> BuildResult {
        let vzConfig = VZVirtualMachineConfiguration()

        Self.logger.debug("Building config: cpuCount=\(config.cpuCount), memoryMB=\(config.memorySizeInBytes / (1024 * 1024)), bootMode=\(config.bootMode.displayName)")

        // Resources
        vzConfig.cpuCount = config.cpuCount
        vzConfig.memorySize = config.memorySizeInBytes

        // Platform & boot loader
        switch config.bootMode {
        case .macOS:
            #if arch(arm64)
            try configureMacOSBoot(vzConfig, config: config, bundleURL: bundleURL)
            #else
            throw ConfigurationBuilderError.macOSGuestRequiresAppleSilicon
            #endif

        case .efi:
            try configureEFIBoot(vzConfig, config: config, bundleURL: bundleURL)

        case .linuxKernel:
            try configureLinuxKernelBoot(vzConfig, config: config)
        }

        // Common devices
        try configureStorage(vzConfig, config: config, bundleURL: bundleURL)
        configureNetwork(vzConfig, config: config)
        configureEntropy(vzConfig)
        configureAudio(vzConfig)
        try configureDirectorySharing(vzConfig, config: config)

        // Serial port
        let (inputPipe, outputPipe) = configureSerialPort(vzConfig)

        // Validate
        try vzConfig.validate()

        Self.logger.info("Built VZ configuration for '\(config.name)' (\(config.bootMode.displayName))")
        return BuildResult(configuration: vzConfig, serialInputPipe: inputPipe, serialOutputPipe: outputPipe)
    }

    // MARK: - macOS Boot

    #if arch(arm64)
    private func configureMacOSBoot(
        _ vzConfig: VZVirtualMachineConfiguration,
        config: VMConfiguration,
        bundleURL: URL
    ) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let platform = VZMacPlatformConfiguration()

        // Auxiliary storage
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: layout.auxiliaryStorageURL)

        // Hardware model
        if let modelData = config.hardwareModelData,
           let hardwareModel = VZMacHardwareModel(dataRepresentation: modelData) {
            platform.hardwareModel = hardwareModel
        } else {
            let modelData = try Data(contentsOf: layout.hardwareModelURL)
            guard let hardwareModel = VZMacHardwareModel(dataRepresentation: modelData) else {
                throw ConfigurationBuilderError.invalidHardwareModel
            }
            platform.hardwareModel = hardwareModel
        }

        // Machine identifier
        if let idData = config.machineIdentifierData,
           let machineID = VZMacMachineIdentifier(dataRepresentation: idData) {
            platform.machineIdentifier = machineID
        } else {
            let idData = try Data(contentsOf: layout.machineIdentifierURL)
            guard let machineID = VZMacMachineIdentifier(dataRepresentation: idData) else {
                throw ConfigurationBuilderError.invalidMachineIdentifier
            }
            platform.machineIdentifier = machineID
        }

        vzConfig.platform = platform
        vzConfig.bootLoader = VZMacOSBootLoader()

        // macOS-specific devices
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: config.displayWidth,
                heightInPixels: config.displayHeight,
                pixelsPerInch: config.displayPPI
            )
        ]
        vzConfig.graphicsDevices = [graphics]

        vzConfig.pointingDevices = [VZMacTrackpadConfiguration()]
        vzConfig.keyboards = [VZMacKeyboardConfiguration()]
    }
    #endif

    // MARK: - EFI Boot

    private func configureEFIBoot(
        _ vzConfig: VZVirtualMachineConfiguration,
        config: VMConfiguration,
        bundleURL: URL
    ) throws {
        let platform = VZGenericPlatformConfiguration()
        if let idData = config.genericMachineIdentifierData,
           let machineID = VZGenericMachineIdentifier(dataRepresentation: idData) {
            platform.machineIdentifier = machineID
        }
        vzConfig.platform = platform

        let layout = VMBundleLayout(bundleURL: bundleURL)
        let variableStore: VZEFIVariableStore
        if FileManager.default.fileExists(atPath: layout.efiVariableStoreURL.path(percentEncoded: false)) {
            variableStore = VZEFIVariableStore(url: layout.efiVariableStoreURL)
        } else {
            variableStore = try VZEFIVariableStore(creatingVariableStoreAt: layout.efiVariableStoreURL, options: [])
        }

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = variableStore
        vzConfig.bootLoader = bootLoader

        // Linux graphics
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: config.displayWidth,
                heightInPixels: config.displayHeight
            )
        ]
        vzConfig.graphicsDevices = [graphics]

        vzConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        vzConfig.keyboards = [VZUSBKeyboardConfiguration()]
    }

    // MARK: - Linux Kernel Boot

    private func configureLinuxKernelBoot(
        _ vzConfig: VZVirtualMachineConfiguration,
        config: VMConfiguration
    ) throws {
        let platform = VZGenericPlatformConfiguration()
        if let idData = config.genericMachineIdentifierData,
           let machineID = VZGenericMachineIdentifier(dataRepresentation: idData) {
            platform.machineIdentifier = machineID
        }
        vzConfig.platform = platform

        guard let kernelPath = config.kernelPath else {
            throw ConfigurationBuilderError.missingKernelPath
        }

        let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: kernelPath))
        if let initrdPath = config.initrdPath {
            bootLoader.initialRamdiskURL = URL(fileURLWithPath: initrdPath)
        }
        bootLoader.commandLine = config.kernelCommandLine ?? "console=hvc0"
        vzConfig.bootLoader = bootLoader

        // Linux graphics
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: config.displayWidth,
                heightInPixels: config.displayHeight
            )
        ]
        vzConfig.graphicsDevices = [graphics]

        vzConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        vzConfig.keyboards = [VZUSBKeyboardConfiguration()]
    }

    // MARK: - Common Devices

    private func configureStorage(
        _ vzConfig: VZVirtualMachineConfiguration,
        config: VMConfiguration,
        bundleURL: URL
    ) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        guard FileManager.default.fileExists(atPath: layout.diskImageURL.path(percentEncoded: false)) else {
            throw ConfigurationBuilderError.diskImageNotFound(layout.diskImageURL)
        }

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: layout.diskImageURL, readOnly: false)
        let storage = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        vzConfig.storageDevices = [storage]

        // Attach ISO as USB mass storage device
        if let isoPath = config.isoPath {
            let isoURL = URL(fileURLWithPath: isoPath)
            if FileManager.default.fileExists(atPath: isoURL.path(percentEncoded: false)) {
                do {
                    let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
                    let usbStorage = VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment)
                    // For EFI boot with boot-from-disc enabled, insert before main disk
                    // so the firmware discovers the ISO first
                    if config.bootFromDiscImage && config.bootMode == .efi {
                        vzConfig.storageDevices.insert(usbStorage, at: 0)
                    } else {
                        vzConfig.storageDevices.append(usbStorage)
                    }
                } catch {
                    Self.logger.warning("Failed to attach ISO at \(isoPath): \(error.localizedDescription)")
                }
            } else {
                Self.logger.warning("ISO not found at \(isoPath), skipping — VM will boot from disk")
            }
        }
    }

    private func configureNetwork(_ vzConfig: VZVirtualMachineConfiguration, config: VMConfiguration) {
        guard config.networkEnabled else { return }

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()

        if let macString = config.macAddress,
           let macAddress = VZMACAddress(string: macString) {
            networkDevice.macAddress = macAddress
        }

        vzConfig.networkDevices = [networkDevice]
    }

    private func configureEntropy(_ vzConfig: VZVirtualMachineConfiguration) {
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    }

    private func configureAudio(_ vzConfig: VZVirtualMachineConfiguration) {
        let audioDevice = VZVirtioSoundDeviceConfiguration()

        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()

        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()

        audioDevice.streams = [inputStream, outputStream]
        vzConfig.audioDevices = [audioDevice]
    }

    // MARK: - Serial Port

    /// Configures a bidirectional virtio console serial port using pipe-backed file handles.
    /// Returns the (input, output) pipes for the host side.
    private func configureSerialPort(_ vzConfig: VZVirtualMachineConfiguration) -> (Pipe, Pipe) {
        let inputPipe = Pipe()   // host writes → guest reads
        let outputPipe = Pipe()  // guest writes → host reads

        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
        vzConfig.serialPorts = [serialPort]

        return (inputPipe, outputPipe)
    }

    // MARK: - Directory Sharing

    private func configureDirectorySharing(_ vzConfig: VZVirtualMachineConfiguration, config: VMConfiguration) throws {
        guard let directories = config.sharedDirectories, !directories.isEmpty else { return }

        try validateSharedDirectories(directories)

        switch config.guestOS {
        case .macOS:
            configureMacOSDirectorySharing(vzConfig, directories: directories)
        case .linux:
            configureLinuxDirectorySharing(vzConfig, directories: directories)
        }
    }

    private func validateSharedDirectories(_ directories: [SharedDirectory]) throws {
        let fileManager = FileManager.default
        for directory in directories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
                throw ConfigurationBuilderError.sharedDirectoryNotFound(directory.path)
            }
            guard isDirectory.boolValue else {
                throw ConfigurationBuilderError.sharedDirectoryNotADirectory(directory.path)
            }
            guard fileManager.isReadableFile(atPath: directory.path) else {
                throw ConfigurationBuilderError.sharedDirectoryNotReadable(directory.path)
            }
            if !directory.readOnly {
                guard fileManager.isWritableFile(atPath: directory.path) else {
                    throw ConfigurationBuilderError.sharedDirectoryNotWritable(directory.path)
                }
            }
        }
    }

    private func configureMacOSDirectorySharing(
        _ vzConfig: VZVirtualMachineConfiguration,
        directories: [SharedDirectory]
    ) {
        // macOS guests use a single device with the automount tag.
        // All directories are bundled into a VZMultipleDirectoryShare.
        var shareMap: [String: VZSharedDirectory] = [:]
        for directory in directories {
            var name = directory.displayName
            // Handle name collisions by prefixing with a UUID fragment
            if shareMap[name] != nil {
                name = "\(directory.id.uuidString.prefix(8))-\(name)"
            }
            shareMap[name] = VZSharedDirectory(url: URL(fileURLWithPath: directory.path), readOnly: directory.readOnly)
        }

        let multiShare = VZMultipleDirectoryShare(directories: shareMap)
        let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        device.share = multiShare

        vzConfig.directorySharingDevices = [device]
    }

    private func configureLinuxDirectorySharing(
        _ vzConfig: VZVirtualMachineConfiguration,
        directories: [SharedDirectory]
    ) {
        // Linux guests get one device per directory with sequential tags (share0, share1, ...).
        var devices: [VZVirtioFileSystemDeviceConfiguration] = []
        for (index, directory) in directories.enumerated() {
            let share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: URL(fileURLWithPath: directory.path), readOnly: directory.readOnly)
            )
            let device = VZVirtioFileSystemDeviceConfiguration(tag: "share\(index)")
            device.share = share
            devices.append(device)
        }
        vzConfig.directorySharingDevices = devices
    }
}

// MARK: - Errors

enum ConfigurationBuilderError: LocalizedError {
    case macOSGuestRequiresAppleSilicon
    case invalidHardwareModel
    case invalidMachineIdentifier
    case missingKernelPath
    case diskImageNotFound(URL)
    case sharedDirectoryNotFound(String)
    case sharedDirectoryNotADirectory(String)
    case sharedDirectoryNotReadable(String)
    case sharedDirectoryNotWritable(String)

    var errorDescription: String? {
        switch self {
        case .macOSGuestRequiresAppleSilicon:
            "macOS guests can only run on Apple Silicon."
        case .invalidHardwareModel:
            "The stored hardware model data is invalid."
        case .invalidMachineIdentifier:
            "The stored machine identifier data is invalid."
        case .missingKernelPath:
            "A kernel path is required for Linux kernel boot mode."
        case .diskImageNotFound(let url):
            "Disk image not found at \(url.path(percentEncoded: false))."
        case .sharedDirectoryNotFound(let path):
            "Shared directory not found at \(path)."
        case .sharedDirectoryNotADirectory(let path):
            "Shared path is not a directory: \(path)."
        case .sharedDirectoryNotReadable(let path):
            "Shared directory is not readable: \(path)."
        case .sharedDirectoryNotWritable(let path):
            "Shared directory is not writable: \(path)."
        }
    }
}
