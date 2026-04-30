import Foundation
import Virtualization
import os

/// Translates a `VMConfiguration` into a `VZVirtualMachineConfiguration`.
///
/// Resolves symlinks and validates all user-supplied file paths (kernel, initrd, disc image,
/// additional disks, shared directories) before passing them to Virtualization.framework.
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
        configureAudio(vzConfig, config: config)
        configureUSBControllers(vzConfig)
        try configureDirectorySharing(vzConfig, config: config)

        // Serial port
        let (inputPipe, outputPipe) = configureSerialPort(vzConfig)

        // Clipboard sharing (SPICE agent console port)
        let clipboardPipes = configureClipboardSharing(vzConfig, config: config)

        // Vsock device for the Kernova guest <-> host channel (macOS guests only).
        // The listener and any per-service consumers are wired up post-VM-create
        // by VMInstance.startVsockServices(); the Linux SPICE/virtio-console path
        // remains the clipboard transport for Linux guests.
        if config.bootMode == .macOS {
            configureVsockDevice(vzConfig)
        }

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

        let kernel = try Self.resolveFile(at: kernelPath, context: "Kernel",
                                          notFound: .kernelNotFound(kernelPath),
                                          isDirectory: .kernelPathIsDirectory(kernelPath))

        let bootLoader = VZLinuxBootLoader(kernelURL: kernel.url)
        if let initrdPath = config.initrdPath {
            let initrd = try Self.resolveFile(at: initrdPath, context: "Initrd",
                                              notFound: .initrdNotFound(initrdPath),
                                              isDirectory: .initrdPathIsDirectory(initrdPath))
            bootLoader.initialRamdiskURL = initrd.url
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

        // Attach disc image as USB mass storage device
        if let discImagePath = config.discImagePath {
            let discImage = try Self.resolveFile(at: discImagePath, context: "Disc image",
                                                 requireWritable: !config.discImageReadOnly,
                                                 notFound: .discImageNotFound(discImagePath),
                                                 isDirectory: .discImagePathIsDirectory(discImagePath),
                                                 notWritable: .discImageNotWritable(discImagePath))

            let discImageAttachment: VZDiskImageStorageDeviceAttachment
            do {
                discImageAttachment = try VZDiskImageStorageDeviceAttachment(url: discImage.url, readOnly: config.discImageReadOnly)
            } catch {
                Self.logger.error("Failed to attach disc image at '\(discImagePath, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                throw error
            }
            let usbStorage = VZUSBMassStorageDeviceConfiguration(attachment: discImageAttachment)
            // For EFI boot with boot-from-disc enabled, insert before main disk
            // so the firmware discovers it first
            if config.bootFromDiscImage && config.bootMode == .efi {
                vzConfig.storageDevices.insert(usbStorage, at: 0)
            } else {
                vzConfig.storageDevices.append(usbStorage)
            }
        }

        // Attach additional virtio block devices
        if let additionalDisks = config.additionalDisks {
            for disk in additionalDisks {
                let resolved = try Self.resolveFile(
                    at: disk.path, context: "Additional disk '\(disk.label)'",
                    requireWritable: !disk.readOnly,
                    notFound: .additionalDiskNotFound(disk.path, disk.label),
                    isDirectory: .additionalDiskPathIsDirectory(disk.path, disk.label),
                    notWritable: .additionalDiskNotWritable(disk.path, disk.label))

                let attachment: VZDiskImageStorageDeviceAttachment
                do {
                    attachment = try VZDiskImageStorageDeviceAttachment(url: resolved.url, readOnly: disk.readOnly)
                } catch {
                    Self.logger.error("Failed to attach additional disk '\(disk.label, privacy: .public)' at '\(disk.path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                    throw error
                }
                let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                blockDevice.blockDeviceIdentifier = disk.blockDeviceIdentifier
                vzConfig.storageDevices.append(blockDevice)

                Self.logger.debug("Attached additional disk '\(disk.label, privacy: .public)' (id: \(disk.blockDeviceIdentifier, privacy: .public), readOnly: \(disk.readOnly, privacy: .public))")
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

    private func configureAudio(_ vzConfig: VZVirtualMachineConfiguration, config: VMConfiguration) {
        Self.logger.debug("Configuring audio: microphoneEnabled=\(config.microphoneEnabled, privacy: .public)")
        let audioDevice = VZVirtioSoundDeviceConfiguration()

        var streams: [VZVirtioSoundDeviceStreamConfiguration] = []

        if config.microphoneEnabled {
            let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
            inputStream.source = VZHostAudioInputStreamSource()
            streams.append(inputStream)
        }

        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        streams.append(outputStream)

        audioDevice.streams = streams
        vzConfig.audioDevices = [audioDevice]
    }

    /// Configures an XHCI USB controller unconditionally so that runtime USB device hot-plug
    /// is always available via `USBDeviceService`.
    private func configureUSBControllers(_ vzConfig: VZVirtualMachineConfiguration) {
        vzConfig.usbControllers = [VZXHCIControllerConfiguration()]
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
    /// Linux guests only — macOS guests sync clipboard over vsock (port
    /// `KernovaVsockPort.clipboard`) instead of a SPICE console port, so the
    /// SPICE pipes are not configured for them.
    ///
    /// Returns the (input, output) pipes, or `nil` when clipboard sharing is
    /// disabled or routed over vsock instead.
    private func configureClipboardSharing(
        _ vzConfig: VZVirtualMachineConfiguration,
        config: VMConfiguration
    ) -> (input: Pipe, output: Pipe)? {
        guard config.clipboardSharingEnabled else { return nil }
        guard config.guestOS == .linux else { return nil }

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

        vzConfig.consoleDevices.append(consoleDevice)

        Self.logger.info("Configured SPICE clipboard console port for '\(config.name, privacy: .public)'")
        return (inputPipe, outputPipe)
    }

    // MARK: - Vsock

    /// Adds a single virtio-socket device to the configuration. Listeners are
    /// installed post-VM-create against the live `VZVirtioSocketDevice` rather
    /// than declared on the configuration.
    private func configureVsockDevice(_ vzConfig: VZVirtualMachineConfiguration) {
        let socketDevice = VZVirtioSocketDeviceConfiguration()
        vzConfig.socketDevices.append(socketDevice)
        Self.logger.info("Configured virtio-socket device for guest <-> host channel")
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
        var resolvedURLs: [URL] = []
        for directory in directories {
            let resolved = try Self.resolveDirectory(
                at: directory.path, context: "Shared directory",
                requireReadable: true, requireWritable: !directory.readOnly,
                notFound: .sharedDirectoryNotFound(directory.path),
                notADirectory: .sharedDirectoryNotADirectory(directory.path),
                notReadable: .sharedDirectoryNotReadable(directory.path),
                notWritable: .sharedDirectoryNotWritable(directory.path))
            resolvedURLs.append(resolved.url)
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

    // MARK: - Path Validation Helpers

    /// Resolves and validates a file path, mapping `PathValidation.Failure` to `ConfigurationBuilderError`.
    private static func resolveFile(
        at path: String,
        context: String,
        requireWritable: Bool = false,
        notFound: ConfigurationBuilderError,
        isDirectory: ConfigurationBuilderError,
        notWritable: ConfigurationBuilderError? = nil
    ) throws -> PathValidation.ResolvedPath {
        do {
            let resolved = try PathValidation.resolveFile(at: path, requireWritable: requireWritable)
            resolved.logResolution(logger: logger, context: context)
            return resolved
        } catch {
            switch error {
            case .notFound:
                logger.error("\(context, privacy: .public) not found at '\(path, privacy: .public)'")
                throw notFound
            case .unexpectedType:
                logger.error("\(context, privacy: .public) path is a directory: '\(path, privacy: .public)'")
                throw isDirectory
            case .notWritable:
                logger.error("\(context, privacy: .public) is not writable: '\(path, privacy: .public)'")
                guard let notWritableError = notWritable else {
                    logger.fault("resolveFile called with requireWritable but no notWritable error for '\(path, privacy: .public)'")
                    assertionFailure("'notWritable' error must be provided when 'requireWritable' is true")
                    throw notFound
                }
                throw notWritableError
            case .notReadable:
                logger.fault("Unexpected .notReadable from resolveFile for '\(path, privacy: .public)'")
                assertionFailure("resolveFile should never throw .notReadable")
                throw notFound
            }
        }
    }

    /// Resolves and validates a directory path, mapping `PathValidation.Failure` to `ConfigurationBuilderError`.
    private static func resolveDirectory(
        at path: String,
        context: String,
        requireReadable: Bool = false,
        requireWritable: Bool = false,
        notFound: ConfigurationBuilderError,
        notADirectory: ConfigurationBuilderError,
        notReadable: ConfigurationBuilderError? = nil,
        notWritable: ConfigurationBuilderError? = nil
    ) throws -> PathValidation.ResolvedPath {
        do {
            let resolved = try PathValidation.resolveDirectory(
                at: path, requireReadable: requireReadable, requireWritable: requireWritable)
            resolved.logResolution(logger: logger, context: context)
            return resolved
        } catch {
            switch error {
            case .notFound:
                logger.error("\(context, privacy: .public) not found at '\(path, privacy: .public)'")
                throw notFound
            case .unexpectedType:
                logger.error("\(context, privacy: .public) path is not a directory: '\(path, privacy: .public)'")
                throw notADirectory
            case .notReadable:
                logger.error("\(context, privacy: .public) is not readable: '\(path, privacy: .public)'")
                guard let notReadableError = notReadable else {
                    logger.fault("resolveDirectory called with requireReadable but no notReadable error for '\(path, privacy: .public)'")
                    assertionFailure("'notReadable' error must be provided when 'requireReadable' is true")
                    throw notFound
                }
                throw notReadableError
            case .notWritable:
                logger.error("\(context, privacy: .public) is not writable: '\(path, privacy: .public)'")
                guard let notWritableError = notWritable else {
                    logger.fault("resolveDirectory called with requireWritable but no notWritable error for '\(path, privacy: .public)'")
                    assertionFailure("'notWritable' error must be provided when 'requireWritable' is true")
                    throw notFound
                }
                throw notWritableError
            }
        }
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
    case discImageNotFound(String)
    case discImagePathIsDirectory(String)
    case discImageNotWritable(String)
    case diskImageNotFound(URL)
    case additionalDiskNotFound(String, String)
    case additionalDiskPathIsDirectory(String, String)
    case additionalDiskNotWritable(String, String)
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
        case .discImageNotFound(let path):
            "Disc image not found at \(path). Remove the disc image path from your VM configuration if the media is no longer needed."
        case .discImagePathIsDirectory(let path):
            "Disc image path is a directory, not a file: \(path)."
        case .discImageNotWritable(let path):
            "Disc image is not writable: \(path). Change it to read-only or select a writable file."
        case .additionalDiskNotFound(let path, let label):
            "Additional disk '\(label)' not found at \(path)."
        case .additionalDiskPathIsDirectory(let path, let label):
            "Additional disk '\(label)' path is a directory, not a file: \(path)."
        case .additionalDiskNotWritable(let path, let label):
            "Additional disk '\(label)' is not writable: \(path). Change it to read-only or select a writable file."
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
