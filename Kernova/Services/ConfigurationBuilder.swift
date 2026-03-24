import Foundation
import Virtualization
import os

/// Translates a `VMConfiguration` into a `VZVirtualMachineConfiguration`.
///
/// Resolves symlinks and validates all user-supplied file paths (kernel, initrd, ISO,
/// shared directories) before passing them to Virtualization.framework.
///
/// Supports three boot paths:
/// - **macOS**: `VZMacPlatformConfiguration` + `VZMacOSBootLoader` (Apple Silicon only)
/// - **EFI**: `VZGenericPlatformConfiguration` + `VZEFIBootLoader` (Linux guests)
/// - **Linux Kernel**: `VZGenericPlatformConfiguration` + `VZLinuxBootLoader`
struct ConfigurationBuilder: Sendable {

    /// Contains the built VZ configuration along with bidirectional serial port pipes
    /// and optional SPICE clipboard pipes.
    struct BuildResult: @unchecked Sendable {
        let configuration: VZVirtualMachineConfiguration
        let serialInputPipe: Pipe
        let serialOutputPipe: Pipe
        let clipboardInputPipe: Pipe?
        let clipboardOutputPipe: Pipe?
    }

    private static let logger = Logger(subsystem: "com.kernova.app", category: "ConfigurationBuilder")

    /// Builds a validated `VZVirtualMachineConfiguration` from the given VM configuration and bundle URL.
    func build(from config: VMConfiguration, bundleURL: URL) throws -> BuildResult {
        let vzConfig = VZVirtualMachineConfiguration()

        Self.logger.debug("Building config: cpuCount=\(config.cpuCount, privacy: .public), memoryMB=\(config.memorySizeInBytes / (1024 * 1024), privacy: .public), bootMode=\(config.bootMode.displayName, privacy: .public)")

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

        // Clipboard sharing (SPICE agent console port)
        let clipboardPipes = configureClipboardSharing(vzConfig, config: config)

        // Validate
        try vzConfig.validate()

        Self.logger.info("Built VZ configuration for '\(config.name, privacy: .public)' (\(config.bootMode.displayName, privacy: .public))")
        return BuildResult(
            configuration: vzConfig,
            serialInputPipe: inputPipe,
            serialOutputPipe: outputPipe,
            clipboardInputPipe: clipboardPipes?.input,
            clipboardOutputPipe: clipboardPipes?.output
        )
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
            Self.logger.error("Kernel path is required but not set for VM '\(config.name, privacy: .public)'")
            throw ConfigurationBuilderError.missingKernelPath
        }

        let fileManager = FileManager.default
        let kernelURL = URL(fileURLWithPath: kernelPath).resolvingSymlinksInPath()
        let resolvedKernelPath = kernelURL.path(percentEncoded: false)

        if resolvedKernelPath != kernelPath {
            Self.logger.info("Kernel path '\(kernelPath, privacy: .public)' resolved to '\(resolvedKernelPath, privacy: .public)'")
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedKernelPath, isDirectory: &isDirectory) else {
            Self.logger.error("Kernel image not found at '\(kernelPath, privacy: .public)' (resolved: '\(resolvedKernelPath, privacy: .public)')")
            throw ConfigurationBuilderError.kernelNotFound(kernelPath)
        }
        guard !isDirectory.boolValue else {
            Self.logger.error("Kernel path is a directory, not a file: '\(kernelPath, privacy: .public)' (resolved: '\(resolvedKernelPath, privacy: .public)')")
            throw ConfigurationBuilderError.kernelPathIsDirectory(kernelPath)
        }

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        if let initrdPath = config.initrdPath {
            let initrdURL = URL(fileURLWithPath: initrdPath).resolvingSymlinksInPath()
            let resolvedInitrdPath = initrdURL.path(percentEncoded: false)

            if resolvedInitrdPath != initrdPath {
                Self.logger.info("Initrd path '\(initrdPath, privacy: .public)' resolved to '\(resolvedInitrdPath, privacy: .public)'")
            }

            var isInitrdDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolvedInitrdPath, isDirectory: &isInitrdDirectory) else {
                Self.logger.error("Initial ramdisk not found at '\(initrdPath, privacy: .public)' (resolved: '\(resolvedInitrdPath, privacy: .public)')")
                throw ConfigurationBuilderError.initrdNotFound(initrdPath)
            }
            guard !isInitrdDirectory.boolValue else {
                Self.logger.error("Initrd path is a directory, not a file: '\(initrdPath, privacy: .public)' (resolved: '\(resolvedInitrdPath, privacy: .public)')")
                throw ConfigurationBuilderError.initrdPathIsDirectory(initrdPath)
            }
            bootLoader.initialRamdiskURL = initrdURL
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
            Self.logger.error("Disk image not found at '\(layout.diskImageURL.path(percentEncoded: false), privacy: .public)'")
            throw ConfigurationBuilderError.diskImageNotFound(layout.diskImageURL)
        }

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: layout.diskImageURL, readOnly: false)
        let storage = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        vzConfig.storageDevices = [storage]

        // Attach ISO as USB mass storage device
        if let isoPath = config.isoPath {
            let isoURL = URL(fileURLWithPath: isoPath).resolvingSymlinksInPath()
            let resolvedISOPath = isoURL.path(percentEncoded: false)

            if resolvedISOPath != isoPath {
                Self.logger.info("ISO path '\(isoPath, privacy: .public)' resolved to '\(resolvedISOPath, privacy: .public)'")
            }

            var isISODirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedISOPath, isDirectory: &isISODirectory) else {
                Self.logger.error("ISO image not found at '\(isoPath, privacy: .public)' (resolved: '\(resolvedISOPath, privacy: .public)')")
                throw ConfigurationBuilderError.isoImageNotFound(isoPath)
            }
            guard !isISODirectory.boolValue else {
                Self.logger.error("ISO path is a directory, not a file: '\(isoPath, privacy: .public)' (resolved: '\(resolvedISOPath, privacy: .public)')")
                throw ConfigurationBuilderError.isoImagePathIsDirectory(isoPath)
            }

            let isoAttachment: VZDiskImageStorageDeviceAttachment
            do {
                isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            } catch {
                Self.logger.error("Failed to attach ISO at '\(isoPath, privacy: .public)' (resolved: '\(resolvedISOPath, privacy: .public)'): \(error.localizedDescription, privacy: .public)")
                throw error
            }
            let usbStorage = VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment)
            // For EFI boot with boot-from-disc enabled, insert before main disk
            // so the firmware discovers the ISO first
            if config.bootFromDiscImage && config.bootMode == .efi {
                vzConfig.storageDevices.insert(usbStorage, at: 0)
            } else {
                vzConfig.storageDevices.append(usbStorage)
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

    // MARK: - Clipboard Sharing

    /// Configures a SPICE agent console port for clipboard sharing using raw pipe I/O.
    ///
    /// Instead of using `VZSpiceAgentPortAttachment` (which automatically syncs with
    /// the host `NSPasteboard`), we attach `VZFileHandleSerialPortAttachment` to the
    /// SPICE-named port. This lets `SpiceClipboardService` speak the SPICE protocol
    /// directly and present clipboard data in a gated UI rather than hijacking the
    /// host clipboard.
    ///
    /// Returns the (input, output) pipes, or `nil` when clipboard sharing is disabled.
    private func configureClipboardSharing(
        _ vzConfig: VZVirtualMachineConfiguration,
        config: VMConfiguration
    ) -> (input: Pipe, output: Pipe)? {
        guard config.clipboardSharingEnabled else { return nil }

        let inputPipe = Pipe()   // host writes → guest reads
        let outputPipe = Pipe()  // guest writes → host reads

        let consoleDevice = VZVirtioConsoleDeviceConfiguration()

        let spicePort = VZVirtioConsolePortConfiguration()
        spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        spicePort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
        spicePort.isConsole = false
        consoleDevice.ports[0] = spicePort

        vzConfig.consoleDevices = [consoleDevice]

        Self.logger.info("Configured SPICE clipboard console port for '\(config.name, privacy: .public)'")
        return (inputPipe, outputPipe)
    }

    // MARK: - Directory Sharing

    private func configureDirectorySharing(_ vzConfig: VZVirtualMachineConfiguration, config: VMConfiguration) throws {
        guard let directories = config.sharedDirectories, !directories.isEmpty else { return }

        let resolvedURLs = try validateSharedDirectories(directories)

        switch config.guestOS {
        case .macOS:
            configureMacOSDirectorySharing(vzConfig, directories: directories, resolvedURLs: resolvedURLs)
        case .linux:
            configureLinuxDirectorySharing(vzConfig, directories: directories, resolvedURLs: resolvedURLs)
        }
    }

    /// Validates shared directories and returns resolved URLs (symlinks followed).
    private func validateSharedDirectories(_ directories: [SharedDirectory]) throws -> [URL] {
        let fileManager = FileManager.default
        var resolvedURLs: [URL] = []
        for directory in directories {
            let resolvedURL = URL(fileURLWithPath: directory.path).resolvingSymlinksInPath()
            let resolvedPath = resolvedURL.path(percentEncoded: false)

            if resolvedPath != directory.path {
                Self.logger.info("Shared directory '\(directory.path, privacy: .public)' resolved to '\(resolvedPath, privacy: .public)'")
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
                Self.logger.error("Shared directory not found at '\(directory.path, privacy: .public)' (resolved: '\(resolvedPath, privacy: .public)')")
                throw ConfigurationBuilderError.sharedDirectoryNotFound(directory.path)
            }
            guard isDirectory.boolValue else {
                Self.logger.error("Shared path is not a directory: '\(directory.path, privacy: .public)' (resolved: '\(resolvedPath, privacy: .public)')")
                throw ConfigurationBuilderError.sharedDirectoryNotADirectory(directory.path)
            }
            guard fileManager.isReadableFile(atPath: resolvedPath) else {
                Self.logger.error("Shared directory is not readable: '\(directory.path, privacy: .public)' (resolved: '\(resolvedPath, privacy: .public)')")
                throw ConfigurationBuilderError.sharedDirectoryNotReadable(directory.path)
            }
            if !directory.readOnly {
                guard fileManager.isWritableFile(atPath: resolvedPath) else {
                    Self.logger.error("Shared directory is not writable: '\(directory.path, privacy: .public)' (resolved: '\(resolvedPath, privacy: .public)')")
                    throw ConfigurationBuilderError.sharedDirectoryNotWritable(directory.path)
                }
            }
            resolvedURLs.append(resolvedURL)
        }
        return resolvedURLs
    }

    private func configureMacOSDirectorySharing(
        _ vzConfig: VZVirtualMachineConfiguration,
        directories: [SharedDirectory],
        resolvedURLs: [URL]
    ) {
        // macOS guests use a single device with the automount tag.
        // All directories are bundled into a VZMultipleDirectoryShare.
        var shareMap: [String: VZSharedDirectory] = [:]
        for (index, directory) in directories.enumerated() {
            var name = directory.displayName
            // Handle name collisions by prefixing with a UUID fragment
            if shareMap[name] != nil {
                name = "\(directory.id.uuidString.prefix(8))-\(name)"
            }
            shareMap[name] = VZSharedDirectory(url: resolvedURLs[index], readOnly: directory.readOnly)
        }

        let multiShare = VZMultipleDirectoryShare(directories: shareMap)
        let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        device.share = multiShare

        vzConfig.directorySharingDevices = [device]
    }

    private func configureLinuxDirectorySharing(
        _ vzConfig: VZVirtualMachineConfiguration,
        directories: [SharedDirectory],
        resolvedURLs: [URL]
    ) {
        // Linux guests get one device per directory with sequential tags (share0, share1, ...).
        var devices: [VZVirtioFileSystemDeviceConfiguration] = []
        for (index, directory) in directories.enumerated() {
            let share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: resolvedURLs[index], readOnly: directory.readOnly)
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
    case kernelNotFound(String)
    case kernelPathIsDirectory(String)
    case initrdNotFound(String)
    case initrdPathIsDirectory(String)
    case isoImageNotFound(String)
    case isoImagePathIsDirectory(String)
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
        case .kernelNotFound(let path):
            "Kernel image not found at \(path)."
        case .kernelPathIsDirectory(let path):
            "Kernel path is a directory, not a file: \(path)."
        case .initrdNotFound(let path):
            "Initial ramdisk not found at \(path)."
        case .initrdPathIsDirectory(let path):
            "Initial ramdisk path is a directory, not a file: \(path)."
        case .isoImageNotFound(let path):
            "ISO image not found at \(path). Remove the ISO path from your VM configuration if the installation media is no longer needed."
        case .isoImagePathIsDirectory(let path):
            "ISO image path is a directory, not a file: \(path)."
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
