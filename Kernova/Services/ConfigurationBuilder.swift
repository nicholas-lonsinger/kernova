import CryptoKit
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
        /// `USBDeviceInfo` for each item in `config.removableMedia`,
        /// attached on the XHCI controller at config-build time.
        ///
        /// UUIDs match `VZUSBMassStorageDeviceConfiguration.uuid` so the
        /// runtime tracking in `instance.liveRemovableMedia` can locate
        /// the devices for hot-detach.
        let coldRemovableMedia: [USBDeviceInfo]
    }

    private static let logger = Logger(subsystem: "com.kernova.app", category: "ConfigurationBuilder")

    /// Builds a validated `VZVirtualMachineConfiguration` from the given VM configuration and bundle URL.
    func build(from config: VMConfiguration, bundleURL: URL) throws -> BuildResult {
        try assemble(from: config, bundleURL: bundleURL, validate: true)
    }

    /// Assembles the `BuildResult` with optional VZ validation.
    ///
    /// Production callers go through `build(from:bundleURL:)` and always
    /// validate. The `validate: false` path exists for tests that need to
    /// inspect the assembled configuration on hosts where `vzConfig.validate()`
    /// throws `VZErrorDomain Code=2 ("Virtualization is not available on this
    /// hardware")` — most notably GitHub's macOS runners, which are themselves
    /// nested VMs without virtualization support.
    func assemble(from config: VMConfiguration, bundleURL: URL, validate: Bool) throws -> BuildResult {
        let vzConfig = VZVirtualMachineConfiguration()

        Self.logger.debug(
            "Building config: cpuCount=\(config.cpuCount, privacy: .public), memoryMB=\(config.memorySizeInBytes / (1024 * 1024), privacy: .public), bootMode=\(config.bootMode.displayName, privacy: .public)"
        )

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

        // Common devices.
        // configureUSBControllers must run before configureRemovableMedia so the
        // XHCI controller exists for items to attach to.
        configureUSBControllers(vzConfig)
        try configureStorageDisks(vzConfig, config: config, bundleURL: bundleURL)
        let coldRemovableMedia = try configureRemovableMedia(vzConfig, config: config)
        configureNetwork(vzConfig, config: config)
        configureEntropy(vzConfig)
        configureAudio(vzConfig, config: config)
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
        if validate {
            try vzConfig.validate()
        }

        Self.logger.info(
            "Built VZ configuration for '\(config.name, privacy: .public)' (\(config.bootMode.displayName, privacy: .public))"
        )
        return BuildResult(
            configuration: vzConfig,
            serialInputPipe: inputPipe,
            serialOutputPipe: outputPipe,
            clipboardInputPipe: clipboardPipes?.input,
            clipboardOutputPipe: clipboardPipes?.output,
            coldRemovableMedia: coldRemovableMedia
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
            let hardwareModel = VZMacHardwareModel(dataRepresentation: modelData)
        {
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
            let machineID = VZMacMachineIdentifier(dataRepresentation: idData)
        {
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
            let machineID = VZGenericMachineIdentifier(dataRepresentation: idData)
        {
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
            let machineID = VZGenericMachineIdentifier(dataRepresentation: idData)
        {
            platform.machineIdentifier = machineID
        }
        vzConfig.platform = platform

        guard let kernelPath = config.kernelPath else {
            Self.logger.error("Kernel path is required but not set for VM '\(config.name, privacy: .public)'")
            throw ConfigurationBuilderError.missingKernelPath
        }

        let kernel = try Self.resolveFile(
            at: kernelPath, context: "Kernel",
            notFound: .kernelNotFound(kernelPath),
            isDirectory: .kernelPathIsDirectory(kernelPath))

        let bootLoader = VZLinuxBootLoader(kernelURL: kernel.url)
        if let initrdPath = config.initrdPath {
            let initrd = try Self.resolveFile(
                at: initrdPath, context: "Initrd",
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

    /// Resolves a `StorageDisk` entry's filesystem location.
    ///
    /// Internal disks are bundle-relative; external disks carry an absolute
    /// host path. The main bundle disk is the conventional internal entry
    /// with `path == "Disk.asif"`.
    ///
    /// For internal disks the resolved URL must stay within the bundle
    /// directory — a `..`-traversing path in a hand-edited / corrupted
    /// `config.json` would otherwise escape the sandbox and read from
    /// arbitrary host locations.
    private func resolvedURL(for disk: StorageDisk, bundleURL: URL) throws -> URL {
        if disk.isInternal {
            let bundlePath = bundleURL.standardizedFileURL.path(percentEncoded: false)
            let resolved = bundleURL.appendingPathComponent(disk.path).standardizedFileURL
            let resolvedPath = resolved.path(percentEncoded: false)
            // Require the resolved path to be inside the bundle. The trailing
            // separator on the prefix guards against bundle "Foo" matching a
            // sibling "Foobar".
            let bundlePrefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
            guard resolvedPath.hasPrefix(bundlePrefix) else {
                Self.logger.fault(
                    "Internal storage disk '\(disk.label, privacy: .public)' resolves outside the bundle: \(resolvedPath, privacy: .public)"
                )
                throw ConfigurationBuilderError.storageDiskNotFound(disk.path, disk.label)
            }
            return resolved
        }
        return URL(fileURLWithPath: disk.path)
    }

    /// Returns `true` when this disk represents the bundle's primary disk
    /// (`Disk.asif`) — the implicit "main disk" that historically had no
    /// `VZVirtioBlockDeviceConfiguration.blockDeviceIdentifier` set on it.
    private static func isMainBundleDisk(_ disk: StorageDisk, layout: VMBundleLayout) -> Bool {
        disk.isInternal && disk.path == layout.diskImageURL.lastPathComponent
    }

    /// Builds the ordered `storageDevices` array from `config.storageDisks`.
    ///
    /// Position [0] boots first on EFI guests. Each entry maps to either a
    /// `VZVirtioBlockDeviceConfiguration` (kind `.virtio`) or a
    /// `VZUSBMassStorageDeviceConfiguration` (kind `.usbMassStorage`).
    /// When the list is `nil` or empty, the builder synthesizes a single
    /// main-disk entry at the bundle's `Disk.asif`.
    private func configureStorageDisks(
        _ vzConfig: VZVirtualMachineConfiguration,
        config: VMConfiguration,
        bundleURL: URL
    ) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let disks: [StorageDisk]
        if let configured = config.storageDisks, !configured.isEmpty {
            disks = configured
        } else {
            disks = [Self.defaultMainDisk(layout: layout)]
        }

        var built: [VZStorageDeviceConfiguration] = []
        for disk in disks {
            // Resolve the on-disk URL VZ will attach. Internal disks are
            // bundle-relative and go through `resolvedURL(for:bundleURL:)`
            // for path-traversal containment + existence. External disks
            // go through the full `PathValidation.resolveFile` pipeline
            // (existence, type check, symlink resolution, writability);
            // we then hand VZ the symlink-resolved URL so the attachment
            // doesn't depend on a host-side symlink that could break at
            // runtime.
            let attachmentURL: URL
            if disk.isInternal {
                attachmentURL = try self.resolvedURL(for: disk, bundleURL: bundleURL)
                guard FileManager.default.fileExists(atPath: attachmentURL.path(percentEncoded: false)) else {
                    Self.logger.error(
                        "Storage disk '\(disk.label, privacy: .public)' not found at '\(attachmentURL.path(percentEncoded: false), privacy: .public)'"
                    )
                    throw ConfigurationBuilderError.storageDiskNotFound(disk.path, disk.label)
                }
            } else {
                let resolved = try Self.resolveFile(
                    at: disk.path, context: "Storage disk '\(disk.label)'",
                    requireWritable: !disk.readOnly,
                    notFound: .storageDiskNotFound(disk.path, disk.label),
                    isDirectory: .storageDiskPathIsDirectory(disk.path, disk.label),
                    notWritable: .storageDiskNotWritable(disk.path, disk.label))
                attachmentURL = resolved.url
            }

            let attachment: VZDiskImageStorageDeviceAttachment
            do {
                attachment = try VZDiskImageStorageDeviceAttachment(
                    url: attachmentURL, readOnly: disk.readOnly)
            } catch {
                Self.logger.error(
                    "Failed to attach storage disk '\(disk.label, privacy: .public)' at '\(attachmentURL.path(percentEncoded: false), privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }

            switch disk.kind {
            case .virtio:
                let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                // Leave the main bundle disk's `blockDeviceIdentifier` unset
                // to match pre-refactor behavior: Linux guests historically
                // had no `/dev/disk/by-id/virtio-*` symlink for the primary
                // disk. Setting it from the synthesized default's fresh UUID
                // would make the by-id name vary across launches, which
                // would break any guest-side `/etc/fstab` entry that relied
                // on it. User-added disks DO get a UUID-derived identifier
                // because their UUID is persisted with the disk entry.
                if !Self.isMainBundleDisk(disk, layout: layout) {
                    blockDevice.blockDeviceIdentifier = disk.blockDeviceIdentifier
                }
                built.append(blockDevice)
            case .usbMassStorage:
                let usbStorage = VZUSBMassStorageDeviceConfiguration(attachment: attachment)
                usbStorage.uuid = disk.id
                built.append(usbStorage)
            }

            Self.logger.debug(
                "Attached storage disk '\(disk.label, privacy: .public)' (kind: \(disk.kind.rawValue, privacy: .public), readOnly: \(disk.readOnly, privacy: .public))"
            )
        }

        vzConfig.storageDevices = built
    }

    /// Attaches every `removableMedia` item to the XHCI controller's
    /// `usbDevices` list and returns the matching `USBDeviceInfo`s for
    /// runtime tracking in `instance.liveRemovableMedia`.
    private func configureRemovableMedia(
        _ vzConfig: VZVirtualMachineConfiguration,
        config: VMConfiguration
    ) throws -> [USBDeviceInfo] {
        guard let items = config.removableMedia, !items.isEmpty else { return [] }
        guard let xhci = vzConfig.usbControllers.first else {
            // configureUSBControllers runs unconditionally upstream, so this is
            // a programming error rather than a recoverable state.
            Self.logger.fault("USB controller missing when attaching removable media")
            preconditionFailure("USB controller must be configured before removable media")
        }

        var infos: [USBDeviceInfo] = []
        var attached: [VZUSBDeviceConfiguration] = xhci.usbDevices
        for item in items {
            let resolved = try Self.resolveFile(
                at: item.path, context: "Removable media '\(item.label)'",
                requireWritable: !item.readOnly,
                notFound: .removableMediaNotFound(item.path, item.label),
                isDirectory: .removableMediaPathIsDirectory(item.path, item.label),
                notWritable: .removableMediaNotWritable(item.path, item.label))

            let attachment: VZDiskImageStorageDeviceAttachment
            do {
                attachment = try VZDiskImageStorageDeviceAttachment(
                    url: resolved.url, readOnly: item.readOnly)
            } catch {
                Self.logger.error(
                    "Failed to attach removable media '\(item.label, privacy: .public)' at '\(item.path, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }

            let usbConfig = VZUSBMassStorageDeviceConfiguration(attachment: attachment)
            usbConfig.uuid = item.id
            attached.append(usbConfig)
            infos.append(USBDeviceInfo(id: item.id, path: item.path, readOnly: item.readOnly))

            Self.logger.debug(
                "Attached removable media '\(item.label, privacy: .public)' on XHCI (readOnly: \(item.readOnly, privacy: .public))"
            )
        }
        xhci.usbDevices = attached
        return infos
    }

    /// Synthesizes the default main-disk entry for a VM whose
    /// `storageDisks` list is empty or absent.
    ///
    /// Visible to other layers so the settings UI can materialize the
    /// implicit main disk into an explicit list entry on first edit.
    static func defaultMainDisk(layout: VMBundleLayout) -> StorageDisk {
        StorageDisk(
            id: stableMainDiskID(forBundleAt: layout.bundleURL),
            path: layout.diskImageURL.lastPathComponent,
            readOnly: false,
            label: "Main Disk",
            isInternal: true,
            kind: .virtio
        )
    }

    /// Deterministic UUID for the synthesized main disk, derived from
    /// the bundle path.
    ///
    /// The synthesizer fires whenever `storageDisks` is nil/empty.
    /// Without stable identity, SwiftUI's `ForEach` would tear down the
    /// main-disk row on every re-render, and `removeStorageDisk`'s
    /// entry-lookup-by-id would miss the row the user just clicked —
    /// silently no-op'ing the entry removal while still trashing the
    /// underlying file. Once the user makes any edit, the list is
    /// persisted with this id and the synthesizer is no longer
    /// consulted.
    private static func stableMainDiskID(forBundleAt bundleURL: URL) -> UUID {
        let digest = SHA256.hash(data: Data(bundleURL.path.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    private func configureNetwork(_ vzConfig: VZVirtualMachineConfiguration, config: VMConfiguration) {
        guard config.networkEnabled else { return }

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()

        if let macString = config.macAddress,
            let macAddress = VZMACAddress(string: macString)
        {
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
    ///
    /// Returns the (input, output) pipes for the host side.
    private func configureSerialPort(_ vzConfig: VZVirtualMachineConfiguration) -> (Pipe, Pipe) {
        let inputPipe = Pipe()  // host writes → guest reads
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

        let inputPipe = Pipe()  // host writes → guest reads
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

    /// Adds a single virtio-socket device to the configuration.
    ///
    /// Listeners are
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
        let device = VZVirtioFileSystemDeviceConfiguration(
            tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
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
                    logger.fault(
                        "resolveFile called with requireWritable but no notWritable error for '\(path, privacy: .public)'"
                    )
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
                    logger.fault(
                        "resolveDirectory called with requireReadable but no notReadable error for '\(path, privacy: .public)'"
                    )
                    assertionFailure("'notReadable' error must be provided when 'requireReadable' is true")
                    throw notFound
                }
                throw notReadableError
            case .notWritable:
                logger.error("\(context, privacy: .public) is not writable: '\(path, privacy: .public)'")
                guard let notWritableError = notWritable else {
                    logger.fault(
                        "resolveDirectory called with requireWritable but no notWritable error for '\(path, privacy: .public)'"
                    )
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
    case storageDiskNotFound(String, String)
    case storageDiskPathIsDirectory(String, String)
    case storageDiskNotWritable(String, String)
    case removableMediaNotFound(String, String)
    case removableMediaPathIsDirectory(String, String)
    case removableMediaNotWritable(String, String)
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
        case .storageDiskNotFound(let path, let label):
            "Storage disk '\(label)' not found at \(path)."
        case .storageDiskPathIsDirectory(let path, let label):
            "Storage disk '\(label)' path is a directory, not a file: \(path)."
        case .storageDiskNotWritable(let path, let label):
            "Storage disk '\(label)' is not writable: \(path). Change it to read-only or select a writable file."
        case .removableMediaNotFound(let path, let label):
            "Removable media '\(label)' not found at \(path)."
        case .removableMediaPathIsDirectory(let path, let label):
            "Removable media '\(label)' path is a directory, not a file: \(path)."
        case .removableMediaNotWritable(let path, let label):
            "Removable media '\(label)' is not writable: \(path). Change it to read-only or select a writable file."
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
