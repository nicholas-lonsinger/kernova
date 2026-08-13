import CryptoKit
import Foundation
import Virtualization
import os

/// Translates a `VMConfiguration` into a `VZVirtualMachineConfiguration`.
///
/// Resolves symlinks and validates all user-supplied file paths (kernel, initrd, disk image,
/// additional disks, shared directories) before passing them to Virtualization.framework.
struct ConfigurationBuilder: Sendable {
    struct BuildResult: @unchecked Sendable {
        let configuration: VZVirtualMachineConfiguration
        let serialInputPipe: Pipe
        let serialOutputPipe: Pipe
        let clipboardInputPipe: Pipe?
        let clipboardOutputPipe: Pipe?
        /// `USBDeviceInfo` for each item in `config.removableMedia`, attached on
        /// the XHCI controller at config-build time.
        ///
        /// UUIDs match `VZUSBMassStorageDeviceConfiguration.uuid` so
        /// `instance.liveRemovableMedia` can locate the devices for hot-detach.
        let coldRemovableMedia: [USBDeviceInfo]
    }

    private static let logger = Logger(subsystem: "app.kernova", category: "ConfigurationBuilder")

    /// The guest-agent installer image to attach to a guest that takes it over
    /// virtio, `nil` when this build carries none.
    var guestAgentDiskURL: URL? = KernovaMacOSAgentInfo.installerDiskImageURL

    /// Host state behind a bridged attachment's interface choice.
    var bridgedInterfaces: any BridgedInterfaceProviding = HostBridgedInterfaceProvider()

    /// What this build's signature authorizes; a fresh instance rather than
    /// `.shared`, which is `@MainActor` while assembly runs off the main actor.
    var entitlements = EntitlementService()

    /// Builds a validated `VZVirtualMachineConfiguration` from the given VM configuration and bundle URL.
    func build(from config: VMConfiguration, bundleURL: URL) throws -> BuildResult {
        try assemble(from: config, bundleURL: bundleURL, validate: true)
    }

    /// Assembles the `BuildResult` with optional VZ validation.
    ///
    /// `validate: false` exists for tests running on hosts where
    /// `vzConfig.validate()` throws `VZErrorDomain Code=2` ("Virtualization is
    /// not available on this hardware") — GitHub's macOS runners are themselves
    /// nested VMs without virtualization support.
    func assemble(from config: VMConfiguration, bundleURL: URL, validate: Bool) throws -> BuildResult {
        let vzConfig = VZVirtualMachineConfiguration()

        Self.logger.debug(
            "Building config: cpuCount=\(config.cpuCount, privacy: .public), memoryMB=\(config.memorySizeInBytes / (1024 * 1024), privacy: .public), bootMode=\(config.bootMode.displayName, privacy: .public)"
        )

        vzConfig.cpuCount = config.cpuCount
        vzConfig.memorySize = config.memorySizeInBytes

        switch config.bootMode {
        case .macOS:
            try configureMacOSBoot(vzConfig, config: config, bundleURL: bundleURL)

        case .efi:
            try configureEFIBoot(vzConfig, config: config, bundleURL: bundleURL)

        case .linuxKernel:
            try configureLinuxKernelBoot(vzConfig, config: config)
        }

        // configureUSBControllers must run before configureRemovableMedia so the
        // XHCI controller exists for items to attach to.
        configureUSBControllers(vzConfig)
        try configureStorageDisks(vzConfig, config: config, bundleURL: bundleURL)
        let guestAgentDiskAttached = configureGuestAgentDisk(vzConfig, config: config, bundleURL: bundleURL)
        let coldRemovableMedia = try configureRemovableMedia(vzConfig, config: config)
        try configureNetwork(vzConfig, config: config)
        configureEntropy(vzConfig)
        configureAudio(vzConfig, config: config)
        try configureDirectorySharing(vzConfig, config: config)

        let (inputPipe, outputPipe) = configureSerialPort(vzConfig)

        let clipboardPipes = configureClipboardSharing(vzConfig, config: config)

        // The Kernova guest <-> host channel is macOS-only; Linux guests keep the
        // SPICE/virtio-console transport.
        if config.bootMode == .macOS {
            configureVsockDevice(vzConfig)
        }

        if validate {
            try validateConfiguration(
                vzConfig, guestAgentDiskAttached: guestAgentDiskAttached, config: config)
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

    private func configureMacOSBoot(
        _ vzConfig: VZVirtualMachineConfiguration,
        config: VMConfiguration,
        bundleURL: URL
    ) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let platform = VZMacPlatformConfiguration()

        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: layout.auxiliaryStorageURL)

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

        configureMacOSDevices(vzConfig, config: config)
    }

    /// Attaches the display, pointing, and keyboard devices for a macOS guest.
    ///
    /// Both input arrays pair the Mac device with its USB equivalent: a guest running
    /// macOS 13.0 or later binds `VZMacTrackpadConfiguration`/`VZMacKeyboardConfiguration`
    /// and ignores the USB devices, while an earlier guest recognizes only the USB ones
    /// (`VZMacTrackpadConfiguration.h`, `VZMacKeyboardConfiguration.h`).
    private func configureMacOSDevices(_ vzConfig: VZVirtualMachineConfiguration, config: VMConfiguration) {
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: config.displayWidth,
                heightInPixels: config.displayHeight,
                pixelsPerInch: config.displayPPI
            )
        ]
        vzConfig.graphicsDevices = [graphics]

        vzConfig.pointingDevices = [
            VZMacTrackpadConfiguration(),
            VZUSBScreenCoordinatePointingDeviceConfiguration(),
        ]
        vzConfig.keyboards = [
            VZMacKeyboardConfiguration(),
            VZUSBKeyboardConfiguration(),
        ]
    }

    #if DEBUG
    /// Test-only access to `configureMacOSDevices`.
    func configureMacOSDevicesForTesting(_ vzConfig: VZVirtualMachineConfiguration, config: VMConfiguration) {
        configureMacOSDevices(vzConfig, config: config)
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
    /// Internal disks are bundle-relative; external disks carry an absolute host
    /// path. An internal disk must resolve *inside* the bundle directory — a
    /// `..`-traversing path in a hand-edited or corrupted `config.json` would
    /// otherwise read from arbitrary host locations.
    private func resolvedURL(for disk: StorageDisk, bundleURL: URL) throws -> URL {
        if disk.isInternal {
            let bundlePath = bundleURL.standardizedFileURL.path(percentEncoded: false)
            let resolved = bundleURL.appendingPathComponent(disk.path).standardizedFileURL
            let resolvedPath = resolved.path(percentEncoded: false)
            // The trailing separator guards against bundle "Foo" matching a
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

    /// Returns `true` when this disk is the bundle's primary disk (`Disk.asif`).
    ///
    /// Path-based, not id-based, so it stays correct after `clonedForNewInstance`
    /// regenerates disk ids.
    static func isMainBundleDisk(_ disk: StorageDisk, layout: VMBundleLayout) -> Bool {
        disk.isInternal && disk.path == layout.diskImageURL.lastPathComponent
    }

    /// Builds the ordered `storageDevices` array from `config.storageDisks`.
    ///
    /// Position [0] boots first on EFI guests. When the list is `nil` or empty,
    /// a single main-disk entry at the bundle's `Disk.asif` is synthesized.
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
            // VZ is handed the symlink-resolved URL, so the attachment doesn't
            // depend on a host-side symlink that could break at runtime.
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
                throw ConfigurationBuilderError.storageDiskAttachFailed(
                    id: disk.id,
                    path: attachmentURL.path(percentEncoded: false),
                    label: disk.label,
                    underlying: error)
            }

            switch disk.kind {
            case .virtio:
                let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                // The main bundle disk's `blockDeviceIdentifier` stays unset: it
                // would come from the synthesized default's fresh UUID, making the
                // guest's `/dev/disk/by-id/virtio-*` name vary across launches and
                // breaking any `/etc/fstab` entry relying on it. User-added disks
                // persist their UUID, so they do get an identifier.
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

    /// Appends the guest-agent installer image for a guest that takes it over
    /// virtio, and reports whether it did.
    ///
    /// Never throws: a guest that boots without the agent disk is a degraded
    /// session, while a guest that refuses to boot is a broken VM. The disk goes
    /// last so every configured disk keeps its index — guests name block devices
    /// by attachment order, and a VM the user never touched must not see its own
    /// disks renamed.
    private func configureGuestAgentDisk(
        _ vzConfig: VZVirtualMachineConfiguration,
        config: VMConfiguration,
        bundleURL: URL
    ) -> Bool {
        guard GuestAgentDiskDelivery.mode(for: config) == .virtio else { return false }
        guard let installerURL = guestAgentDiskURL else {
            Self.logger.warning(
                "No guest agent installer image to attach to '\(config.name, privacy: .public)'")
            return false
        }

        let disk = Self.guestAgentDisk(
            installerPath: installerURL.path(percentEncoded: false), bundleURL: bundleURL)
        do {
            let resolved = try Self.resolveFile(
                at: disk.path, context: "Guest agent disk",
                notFound: .storageDiskNotFound(disk.path, disk.label),
                isDirectory: .storageDiskPathIsDirectory(disk.path, disk.label))
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: resolved.url, readOnly: disk.readOnly)
            let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment)
            blockDevice.blockDeviceIdentifier = disk.blockDeviceIdentifier
            vzConfig.storageDevices.append(blockDevice)
        } catch {
            Self.logger.warning(
                "Couldn't attach the guest agent disk to '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        Self.logger.info(
            "Attached the guest agent disk to '\(config.name, privacy: .public)' as a virtio block device"
        )
        return true
    }

    /// Runs `vzConfig.validate()`, retrying once without the guest-agent disk.
    ///
    /// The retry keeps this feature from turning a VM that used to boot into one
    /// that doesn't — whatever ceiling or collision the extra device crossed,
    /// the configuration the user had before it existed still validates.
    private func validateConfiguration(
        _ vzConfig: VZVirtualMachineConfiguration,
        guestAgentDiskAttached: Bool,
        config: VMConfiguration
    ) throws {
        do {
            try vzConfig.validate()
        } catch {
            guard guestAgentDiskAttached else { throw error }
            Self.logger.warning(
                "Dropping the guest agent disk from '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            vzConfig.storageDevices.removeLast()
            try vzConfig.validate()
        }
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
                throw ConfigurationBuilderError.removableMediaAttachFailed(
                    id: item.id,
                    path: item.path,
                    label: item.label,
                    underlying: error)
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

    /// Synthesizes the default main-disk entry for a VM whose `storageDisks`
    /// list is empty or absent.
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

    /// Synthesizes the guest-agent installer's disk entry.
    ///
    /// The entry is built per boot and never written to `config.storageDisks`:
    /// persisting it would put the app's own bundled resource into the Settings
    /// disk list, the boot-order sheet, and the delete sheet's offer to trash
    /// external files.
    static func guestAgentDisk(installerPath: String, bundleURL: URL) -> StorageDisk {
        StorageDisk(
            id: stableGuestAgentDiskID(forBundleAt: bundleURL),
            path: installerPath,
            readOnly: true,
            label: KernovaMacOSAgentInfo.diskLabel,
            // The path is absolute and outside the bundle, and `.dmg` would
            // otherwise default to the USB bus this delivery exists to avoid.
            isInternal: false,
            kind: .virtio
        )
    }

    /// Deterministic UUID for the synthesized main disk, derived from the bundle path.
    ///
    /// Without stable identity, `removeStorageDisk`'s lookup-by-id would miss the
    /// row the user just clicked — silently no-op'ing the entry removal while
    /// still trashing the underlying file.
    private static func stableMainDiskID(forBundleAt bundleURL: URL) -> UUID {
        stableDiskID(seed: bundleURL.path)
    }

    /// Deterministic UUID for the guest-agent disk, salted so it can never
    /// collide with the main disk's on the same bundle.
    ///
    /// It reaches the guest as `blockDeviceIdentifier`, so a fresh UUID per
    /// launch would vary the disk's guest-side name from one boot to the next.
    private static func stableGuestAgentDiskID(forBundleAt bundleURL: URL) -> UUID {
        stableDiskID(seed: bundleURL.path + "\u{0}guest-agent")
    }

    /// A UUID fixed by `seed`.
    private static func stableDiskID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    private func configureNetwork(_ vzConfig: VZVirtualMachineConfiguration, config: VMConfiguration)
        throws
    {
        guard config.networkEnabled else { return }

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        switch config.networkMode {
        case .shared:
            networkDevice.attachment = VZNATNetworkDeviceAttachment()
        case .bridged:
            networkDevice.attachment = try bridgedAttachment(config: config)
        }

        if let macString = config.macAddress,
            let macAddress = VZMACAddress(string: macString)
        {
            networkDevice.macAddress = macAddress
        }

        vzConfig.networkDevices = [networkDevice]
    }

    /// Resolves the host interface a bridged VM attaches to.
    ///
    /// A persisted interface the host no longer offers narrows to Automatic — the
    /// default-route interface. When neither resolves the start fails: the mode is
    /// never substituted, so the VM neither bridges over an arbitrary interface
    /// nor quietly becomes Shared Network (docs/NETWORKING.md).
    private func bridgedAttachment(config: VMConfiguration) throws
        -> VZBridgedNetworkDeviceAttachment
    {
        guard entitlements.hasVMNetworking else {
            Self.logger.error(
                "Bridged networking requested for '\(config.name, privacy: .public)' in a build without com.apple.vm.networking"
            )
            throw ConfigurationBuilderError.bridgedNetworkingNotEntitled
        }

        let available = bridgedInterfaces.interfaces()
        guard
            let chosen = BridgedInterfaceSelection.choose(
                persisted: config.bridgedInterfaceIdentifier,
                available: available.map(\.identifier),
                primary: bridgedInterfaces.primaryInterfaceIdentifier()),
            let interface = VZBridgedNetworkInterface.networkInterfaces.first(where: {
                $0.identifier == chosen
            })
        else {
            Self.logger.error(
                "Bridged networking requested for '\(config.name, privacy: .public)' with no bridgeable host interface"
            )
            throw ConfigurationBuilderError.noBridgeableInterface
        }

        if let persisted = config.bridgedInterfaceIdentifier, persisted != chosen {
            Self.logger.warning(
                "Bridged interface '\(persisted, privacy: .public)' is unavailable — bridging over '\(chosen, privacy: .public)' instead"
            )
        } else {
            Self.logger.info("Bridging over '\(chosen, privacy: .public)'")
        }
        return VZBridgedNetworkDeviceAttachment(interface: interface)
    }

    private func configureEntropy(_ vzConfig: VZVirtualMachineConfiguration) {
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    }

    private func configureAudio(_ vzConfig: VZVirtualMachineConfiguration, config: VMConfiguration) {
        Self.logger.debug(
            "Configuring audio: audioInputEnabled=\(config.audioInputEnabled, privacy: .public), audioOutputEnabled=\(config.audioOutputEnabled, privacy: .public)"
        )

        var streams: [VZVirtioSoundDeviceStreamConfiguration] = []

        if config.audioInputEnabled {
            let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
            inputStream.source = VZHostAudioInputStreamSource()
            streams.append(inputStream)
        }

        if config.audioOutputEnabled {
            let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
            outputStream.sink = VZHostAudioOutputStreamSink()
            streams.append(outputStream)
        }

        // Omit the device entirely when both directions are off, leaving VZ's
        // default-empty `audioDevices`.
        guard !streams.isEmpty else { return }

        let audioDevice = VZVirtioSoundDeviceConfiguration()
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
    /// The port takes a `VZFileHandleSerialPortAttachment`, not a
    /// `VZSpiceAgentPortAttachment` — the latter syncs the host `NSPasteboard`
    /// automatically, bypassing `SpiceClipboardService`'s gated UI.
    ///
    /// Returns `nil` for macOS guests and when clipboard sharing is disabled.
    ///
    /// The macOS exclusion is load-bearing rather than routing: SPICE needs a
    /// userspace agent inside the guest to read the port, and while Linux ships
    /// `spice-vdagent`, macOS ships nothing comparable. Attaching the port to a
    /// macOS guest therefore exchanges no clipboard data and leaks a
    /// `tty.com.redhat.spice.0X` port across save/restore. Those guests reach
    /// the clipboard over vsock through the guest agent instead.
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
    /// Listeners are installed post-VM-create against the live
    /// `VZVirtioSocketDevice`, not declared on the configuration.
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
        var shareMap: [String: VZSharedDirectory] = [:]
        for (index, directory) in directories.enumerated() {
            var name = directory.displayName
            // Resolve name collisions with a UUID fragment prefix.
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
                logger.error("\(context, privacy: .public) not found at '\(path, privacy: .private)'")
                throw notFound
            case .unexpectedType:
                logger.error("\(context, privacy: .public) path is a directory: '\(path, privacy: .private)'")
                throw isDirectory
            case .notWritable:
                logger.error("\(context, privacy: .public) is not writable: '\(path, privacy: .private)'")
                guard let notWritableError = notWritable else {
                    logger.fault(
                        "resolveFile called with requireWritable but no notWritable error for '\(path, privacy: .private)'"
                    )
                    assertionFailure("'notWritable' error must be provided when 'requireWritable' is true")
                    throw notFound
                }
                throw notWritableError
            case .notReadable:
                logger.fault("Unexpected .notReadable from resolveFile for '\(path, privacy: .private)'")
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
                logger.error("\(context, privacy: .public) not found at '\(path, privacy: .private)'")
                throw notFound
            case .unexpectedType:
                logger.error("\(context, privacy: .public) path is not a directory: '\(path, privacy: .private)'")
                throw notADirectory
            case .notReadable:
                logger.error("\(context, privacy: .public) is not readable: '\(path, privacy: .private)'")
                guard let notReadableError = notReadable else {
                    logger.fault(
                        "resolveDirectory called with requireReadable but no notReadable error for '\(path, privacy: .private)'"
                    )
                    assertionFailure("'notReadable' error must be provided when 'requireReadable' is true")
                    throw notFound
                }
                throw notReadableError
            case .notWritable:
                logger.error("\(context, privacy: .public) is not writable: '\(path, privacy: .private)'")
                guard let notWritableError = notWritable else {
                    logger.fault(
                        "resolveDirectory called with requireWritable but no notWritable error for '\(path, privacy: .private)'"
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
    /// The disk file exists but `VZDiskImageStorageDeviceAttachment` refused it —
    /// commonly the sandbox denying `open` on a path the app no longer holds a
    /// grant for (surfaced as "Operation not supported"), or an invalid image.
    ///
    /// `underlying` must be preserved verbatim, not flattened to a string: the
    /// start path classifies transient file-lock contention off its NSError
    /// domain/code, so discarding it turns a retryable boot into a hard failure.
    case storageDiskAttachFailed(id: UUID, path: String, label: String, underlying: any Error)
    case removableMediaNotFound(String, String)
    case removableMediaPathIsDirectory(String, String)
    case removableMediaNotWritable(String, String)
    /// Removable-media counterpart of `storageDiskAttachFailed`.
    case removableMediaAttachFailed(id: UUID, path: String, label: String, underlying: any Error)
    /// Bridged mode was chosen but the host offers no interface to bridge over.
    case noBridgeableInterface
    /// Bridged mode was chosen in a build whose signature omits
    /// `com.apple.vm.networking`, which VZ needs for any non-NAT attachment.
    case bridgedNetworkingNotEntitled
    case sharedDirectoryNotFound(String)
    case sharedDirectoryNotADirectory(String)
    case sharedDirectoryNotReadable(String)
    case sharedDirectoryNotWritable(String)

    var errorDescription: String? {
        switch self {
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
        case .storageDiskAttachFailed(_, let path, let label, let underlying):
            "Couldn't open storage disk '\(label)' at \(path). The file may have been moved or replaced, or Kernova may no longer have permission to read it. (\(underlying.localizedDescription))"
        case .removableMediaNotFound(let path, let label):
            "Removable media '\(label)' not found at \(path)."
        case .removableMediaPathIsDirectory(let path, let label):
            "Removable media '\(label)' path is a directory, not a file: \(path)."
        case .removableMediaNotWritable(let path, let label):
            "Removable media '\(label)' is not writable: \(path). Change it to read-only or select a writable file."
        case .removableMediaAttachFailed(_, let path, let label, let underlying):
            "Couldn't open removable media '\(label)' at \(path). The file may have been moved or replaced, or Kernova may no longer have permission to read it. (\(underlying.localizedDescription))"
        case .noBridgeableInterface:
            "No host network interface could be chosen for bridged networking. Choose a specific interface in the VM's Network settings, or switch to Shared Network."
        case .bridgedNetworkingNotEntitled:
            "This build of Kernova can't provide bridged networking. Switch the VM's network mode to Shared Network."
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

    /// The framework error behind an attach failure, or `nil` for every other case.
    var underlyingAttachError: (any Error)? {
        switch self {
        case .storageDiskAttachFailed(_, _, _, let underlying),
            .removableMediaAttachFailed(_, _, _, let underlying):
            underlying
        default:
            nil
        }
    }
}
