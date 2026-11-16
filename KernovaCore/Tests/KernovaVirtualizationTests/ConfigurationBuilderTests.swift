import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization
@testable import KernovaVirtualizationTestSupport

@Suite("ConfigurationBuilder Tests", .caseScoped)
struct ConfigurationBuilderTests {
    private let scratch = TestScratchDirectory(prefix: "ConfigurationBuilderTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    /// Returns a Linux/EFI config set to host-only networking.
    private func makeHostOnlyConfig() -> VMConfiguration {
        VMConfiguration(
            name: "Test Linux",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize,
            networkEnabled: true,
            networkMode: .hostOnly)
    }

    // MARK: - Boot Validation

    @Test("Builder throws for kernel boot without kernel path")
    func kernelBootWithoutPath() async throws {
        let bundleURL = try scratch.makeEngineBundle()

        let config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .missingKernelPath = e
            else { return false }
            return true
        }
    }

    // MARK: - Shared Directory Validation

    @Test("Builder throws for missing shared directory path")
    func builderThrowsForMissingSharedDirectoryPath() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let share = SharedDirectory(path: "/nonexistent/path/\(UUID().uuidString)")
        let config = VMConfiguration.testLinux(sharedDirectories: [share])

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            // The entry is named the way the Sharing pane names its row.
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotFound(let id, let path, let label) = e
            else { return false }
            return id == share.id && path == share.path && label == share.displayName
        }
    }

    @Test("Builder throws for symlink to file as shared directory")
    func builderThrowsForSymlinkToFileAsSharedDirectory() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Create a regular file, then symlink to it
        let filePath = bundleURL.appendingPathComponent("a-file").path(percentEncoded: false)
        FileManager.default.createFile(atPath: filePath, contents: nil)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-file").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: filePath)

        let config = VMConfiguration.testLinux(sharedDirectories: [
            SharedDirectory(path: symlinkPath)
        ])

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotADirectory = e
            else { return false }
            return true
        }
    }

    // MARK: - Removable Media

    @Test("Attach failure for removable media throws typed error with item identity")
    func removableMediaAttachFailureThrowsTypedError() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // 100 bytes is not a multiple of the 512-byte sector size, so
        // VZDiskImageStorageDeviceAttachment rejects the file even though it
        // exists and is readable — the same attach-time failure shape as a
        // sandbox-denied open of a stale path.
        let isoPath = bundleURL.appendingPathComponent("bad.iso").path(percentEncoded: false)
        try Data(count: 100).write(to: URL(fileURLWithPath: isoPath))

        let itemID = UUID()
        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.removableMedia = [
            RemovableMediaItem(id: itemID, path: isoPath, readOnly: true, label: "Bad ISO")
        ]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .removableMediaAttachFailed(let id, let path, let label, _) = e
            else { return false }
            return id == itemID && path == isoPath && label == "Bad ISO"
        }
    }

    @Test("Attach failure for external storage disk throws typed error with item identity")
    func storageDiskAttachFailureThrowsTypedError() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Unaligned size — see the removable-media counterpart above.
        let diskPath = bundleURL.appendingPathComponent("bad.img").path(percentEncoded: false)
        try Data(count: 100).write(to: URL(fileURLWithPath: diskPath))

        let diskID = UUID()
        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.storageDisks = [
            StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: bundleURL)),
            StorageDisk(
                id: diskID, path: diskPath, readOnly: true, label: "Bad Disk",
                isInternal: false, kind: .virtio),
        ]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskAttachFailed(let id, let path, let label, _) = e
            else { return false }
            return id == diskID && path == diskPath && label == "Bad Disk"
        }
    }

    @Test(
        "An installer entry attaches the VM's copy of the disk, never the shared file, whichever build named it",
        arguments: [false, true])
    func installerEntryAttachesTheBundleCopy(namedByAnotherBuild: Bool) throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let shared = scratch.url.appendingPathComponent("KernovaMacOSAgent.dmg")
        try Data("shared".utf8).write(to: shared)
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let item = RemovableMediaItem(path: shared.path(percentEncoded: false), readOnly: true)
        let copy = layout.guestAgentDiskCopyURL(for: item)

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.removableMedia = [item]
        // Another build's installer is no file of this build's.
        let builder =
            namedByAnotherBuild
            ? ConfigurationBuilder.testing() : ConfigurationBuilder.testing(guestAgentInstaller: shared)

        try FileManager.default.createDirectory(
            at: layout.guestAgentDiskDirectoryURL, withIntermediateDirectories: true)
        try Data(count: 1_048_576).write(to: copy)
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
        let device = try #require(
            result.configuration.usbControllers.first?.usbDevices.first as? VZUSBMassStorageDeviceConfiguration)
        let attachment = try #require(device.attachment as? VZDiskImageStorageDeviceAttachment)
        #expect(attachment.url.standardizedFileURL == copy.standardizedFileURL)
        // The tracked identity stays the installer's.
        #expect(result.products.coldRemovableMedia.map(\.path) == [shared.path(percentEncoded: false)])
    }

    @Test("Removable media returns coldRemovableMedia infos with matching UUIDs")
    func removableMediaReturnsDeviceInfos() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let isoPath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: isoPath))

        let configuredUUID = UUID()
        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.removableMedia = [
            RemovableMediaItem(id: configuredUUID, path: isoPath, readOnly: true)
        ]

        let builder = ConfigurationBuilder.testing()
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)

        #expect(result.products.coldRemovableMedia.count == 1)
        let info = try #require(result.products.coldRemovableMedia.first)
        #expect(info.id == configuredUUID)
        #expect(info.path == isoPath)
        #expect(info.readOnly == true)

        let xhci = try #require(result.configuration.usbControllers.first)
        let usb = try #require(xhci.usbDevices.first as? VZUSBMassStorageDeviceConfiguration)
        #expect(usb.uuid == configuredUUID)
    }

    @Test("Builder throws for non-writable removable media when readOnly is false")
    func builderThrowsForNonWritableRemovableMedia() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let isoPath = bundleURL.appendingPathComponent("readonly.iso").path(percentEncoded: false)
        FileManager.default.createFile(atPath: isoPath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: isoPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: isoPath) }

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.removableMedia = [RemovableMediaItem(path: isoPath, readOnly: false)]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .removableMediaNotWritable = e
            else { return false }
            return true
        }
    }

    // MARK: - Storage Disks

    @Test("Storage disks list orders devices on storageDevices by position")
    func storageDisksOrderingPreserved() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let isoPath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: isoPath))

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.storageDisks = [
            StorageDisk(path: isoPath, readOnly: true, label: "Installer"),
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
        ]

        let builder = ConfigurationBuilder.testing()
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)

        // Position [0] is the ISO (USB mass storage), [1] is virtio main disk.
        #expect(result.configuration.storageDevices.count == 2)
        #expect(result.configuration.storageDevices.first is VZUSBMassStorageDeviceConfiguration)
        #expect(result.configuration.storageDevices.last is VZVirtioBlockDeviceConfiguration)

        // ISO does NOT live on XHCI — it's on storageDevices for boot.
        let xhci = try #require(result.configuration.usbControllers.first)
        #expect(xhci.usbDevices.isEmpty)
    }

    @Test("StorageDisk.defaultKind dispatches by file extension")
    func defaultKindByExtension() {
        #expect(StorageDisk.defaultKind(forPath: "/tmp/install.iso") == .usbMassStorage)
        #expect(StorageDisk.defaultKind(forPath: "/tmp/Ubuntu.ISO") == .usbMassStorage)
        #expect(StorageDisk.defaultKind(forPath: "/tmp/installer.dmg") == .usbMassStorage)
        #expect(StorageDisk.defaultKind(forPath: "Disk.asif") == .virtio)
        #expect(StorageDisk.defaultKind(forPath: "/tmp/data.img") == .virtio)
        #expect(StorageDisk.defaultKind(forPath: "/tmp/data.qcow2") == .virtio)
        #expect(StorageDisk.defaultKind(forPath: "/tmp/no-ext") == .virtio)
    }

    @Test("Builder throws for non-writable read-write external storage disk")
    func builderThrowsForNonWritableStorageDisk() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let diskPath = bundleURL.appendingPathComponent("readonly-data.asif").path(percentEncoded: false)
        FileManager.default.createFile(atPath: diskPath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: diskPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: diskPath) }

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
            StorageDisk(path: diskPath, readOnly: false, label: "Data", isInternal: false, kind: .virtio),
        ]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskNotWritable = e
            else { return false }
            return true
        }
    }

    // MARK: - Dangling Symlink Tests (Kernel / Initrd / Disk Image)

    // MARK: - Symlink-to-Directory Tests (Kernel / Initrd / Disk Image)

    @Test("Builder throws for symlink to directory as kernel path")
    func builderThrowsForSymlinkToDirectoryAsKernelPath() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let dirPath = bundleURL.appendingPathComponent("kernel-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-kernel-dir").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath, withDestinationPath: dirPath.path(percentEncoded: false))

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.kernelPath = symlinkPath

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .kernelPathIsDirectory = e
            else { return false }
            return true
        }
    }

    // MARK: - Audio

    /// Builds `config` and hands its audio-device stream summary to `assertions`.
    ///
    /// Uses `assemble(validate: false)` so the assertions run even on CI runners
    /// without virtualization (where `vzConfig.validate()` would throw); the
    /// audio device is built in `assemble` regardless of the `validate` flag.
    private func withAudioStreams(
        _ config: VMConfiguration,
        _ assertions: (_ hasInput: Bool, _ hasOutput: Bool, _ deviceCount: Int) -> Void
    ) throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let result = try ConfigurationBuilder.testing().assemble(from: config, bundleURL: bundleURL, validate: false)
        let streams = result.configuration.audioDevices
            .compactMap { $0 as? VZVirtioSoundDeviceConfiguration }
            .flatMap(\.streams)
        assertions(
            streams.contains { $0 is VZVirtioSoundDeviceInputStreamConfiguration },
            streams.contains { $0 is VZVirtioSoundDeviceOutputStreamConfiguration },
            result.configuration.audioDevices.count
        )
    }

    @Test(
        "Audio streams match the input/output toggles; the device is omitted when both are off",
        arguments: [
            (input: true, output: true, hasInput: true, hasOutput: true, deviceCount: 1),
            (input: true, output: false, hasInput: true, hasOutput: false, deviceCount: 1),
            (input: false, output: true, hasInput: false, hasOutput: true, deviceCount: 1),
            (input: false, output: false, hasInput: false, hasOutput: false, deviceCount: 0),
        ]
    )
    func audioStreamsMatchToggles(
        _ c: (input: Bool, output: Bool, hasInput: Bool, hasOutput: Bool, deviceCount: Int)
    ) throws {
        var config = VMConfiguration.testLinux()
        config.audioInputEnabled = c.input
        config.audioOutputEnabled = c.output
        try withAudioStreams(config) { hasInput, hasOutput, deviceCount in
            #expect(hasInput == c.hasInput)
            #expect(hasOutput == c.hasOutput)
            #expect(deviceCount == c.deviceCount)
        }
    }

    // MARK: - Network

    /// Assembles `config` and returns its network devices.
    ///
    /// `assemble(validate: false)` for the same reason as the audio helper: the
    /// device is built regardless of the flag, and CI runners can't validate.
    private func networkDevices(for config: VMConfiguration) throws
        -> [VZNetworkDeviceConfiguration]
    {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        return try ConfigurationBuilder.testing()
            .assemble(from: config, bundleURL: bundleURL, validate: false)
            .configuration.networkDevices
    }

    @Test("NAT without the entitlement attaches one virtio device over NAT")
    func natModeAttachesNAT() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let networks = ScriptedVmnetNetworks()
        let builder = ConfigurationBuilder.testing(networks, entitlements: .unentitled)

        let devices = try builder.assemble(
            from: VMConfiguration.testLinux(), bundleURL: bundleURL, validate: false
        ).configuration.networkDevices
        #expect(devices.count == 1)
        let device = try #require(devices.first as? VZVirtioNetworkDeviceConfiguration)
        #expect(device.attachment is VZNATNetworkDeviceAttachment)
        #expect(networks.operations.createdKinds.isEmpty)
    }

    @Test("A configured MAC address reaches the network device")
    func macAddressReachesTheDevice() throws {
        var config = VMConfiguration.testLinux()
        config.macAddress = "aa:bb:cc:dd:ee:ff"
        let device = try #require(try networkDevices(for: config).first)
        #expect(device.macAddress.string == "aa:bb:cc:dd:ee:ff")
    }

    @Test("An isolated VM attaches its own network of its mode, through a view opened for it")
    func isolatedModesAttachTheVMsOwnNetwork() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let networks = ScriptedVmnetNetworks()
        let attachments = MockVmnetAttachments()
        let builder = ConfigurationBuilder.testing(networks, attachments: attachments, entitlements: .entitled)

        var nat = VMConfiguration.testLinux()
        nat.networkMembership = .isolated
        var hostOnly = makeHostOnlyConfig()
        hostOnly.networkMembership = .isolated
        for (config, kind) in [(nat, VmnetNetworkKind.nat), (hostOnly, .hostOnly)] {
            let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
            #expect(
                result.configuration.networkDevices[0].attachment.map(ObjectIdentifier.init)
                    == attachments.madeIdentities.last)
            #expect(result.products.vmnetNetworks.owner == config.id)
            #expect(networks.service.ipv4Subnet(for: VmnetNetworkID(kind: kind, scope: .vm(config.id))) != nil)
        }

        #expect(networks.operations.createdKinds == [.nat, .hostOnly])
    }

    @Test("A built configuration keeps its vmnet network for as long as it lives")
    func aBuiltConfigurationKeepsItsVmnetNetwork() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let networks = ScriptedVmnetNetworks()
        let attachments = MockVmnetAttachments()
        let builder = ConfigurationBuilder.testing(networks, attachments: attachments, entitlements: .entitled)
        var config = VMConfiguration.testLinux()
        config.networkMembership = .isolated

        // The rest of the result, its session view among it, dies with the
        // closure, so the service lets go of the network.
        var configuration: VZVirtualMachineConfiguration? = try autoreleasepool {
            try builder.assemble(from: config, bundleURL: bundleURL, validate: false).configuration
        }
        #expect(configuration != nil)
        let own = try #require(attachments.madeNetworks.first)
        #expect(networks.service.ipv4Subnet(for: VmnetNetworkID(kind: .nat, scope: .vm(config.id))) == nil)
        #expect(networks.operations.releasedNetworks.isEmpty)

        autoreleasepool { configuration = nil }
        #expect(networks.operations.releasedNetworks == [own])
    }

    @Test("An isolated VM whose own network cannot be materialized builds detached, never on the common one")
    func isolatedModeWithoutItsNetworkBuildsDetached() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let networks = ScriptedVmnetNetworks()
        networks.operations.setCreateNetworkError(TestFailure("network limit reached"))
        let builder = ConfigurationBuilder.testing(networks, entitlements: .entitled)
        var config = VMConfiguration.testLinux()
        config.networkMembership = .isolated

        let devices = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
            .configuration.networkDevices
        #expect(devices[0].attachment == nil)
        #expect(networks.operations.createdKinds == [.nat])
        #expect(networks.service.ipv4Subnet(for: .common(.nat)) == nil)
    }

    @Test("An isolated NAT VM in a build without the entitlement is refused, not put on system NAT")
    func isolatedNATWithoutTheEntitlementThrows() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let builder = ConfigurationBuilder.testing(entitlements: .unentitled)
        var config = VMConfiguration.testLinux()
        config.networkMembership = .isolated

        #expect {
            try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .networkNotEntitled(let network) = e, network.isOwn
            else { return false }
            return true
        }
    }

    @Test("A Host Only network that cannot be materialized builds the device detached")
    func hostOnlyModeWithoutANetworkBuildsDetached() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let networks = ScriptedVmnetNetworks()
        networks.operations.setCreateNetworkError(TestFailure("vmnet refused"))
        let builder = ConfigurationBuilder.testing(networks, entitlements: .entitled)

        // The boot (and a restore from saved state, which rebuilds the same
        // configuration) must succeed; attachment recovery reattaches later.
        let devices = try builder.assemble(
            from: makeHostOnlyConfig(), bundleURL: bundleURL, validate: false
        ).configuration.networkDevices
        #expect(devices.count == 1)
        #expect(devices[0].attachment == nil)
    }

    // MARK: - Input Devices

    @Test("A guest known to run macOS 13+ gets only the Mac input devices")
    func macOSInputDevicesMacPairForModernGuest() {
        // Called directly rather than through `assemble`: the rest of
        // `configureMacOSBoot` needs a real `VZMacHardwareModel`, which only a
        // restore image can mint.
        let vz = VZVirtualMachineConfiguration()
        var config = VMConfiguration(
            name: "Test macOS", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        config.lastSeenGuestOSVersion = "13.5"
        ConfigurationBuilder.testing().configureMacOSDevices(vz, config: config)

        #expect(vz.pointingDevices.count == 1)
        #expect(vz.pointingDevices.first is VZMacTrackpadConfiguration)
        #expect(vz.keyboards.count == 1)
        #expect(vz.keyboards.first is VZMacKeyboardConfiguration)
    }

    @Test("A guest known to predate macOS 13 gets only the USB input devices")
    func macOSInputDevicesUSBPairForOldGuest() {
        let vz = VZVirtualMachineConfiguration()
        var config = VMConfiguration(
            name: "Test macOS", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        config.installedImage = .macOSRestoreImage(version: "12.0.1", build: "21A559")
        ConfigurationBuilder.testing().configureMacOSDevices(vz, config: config)

        #expect(vz.pointingDevices.count == 1)
        #expect(vz.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
        #expect(vz.keyboards.count == 1)
        #expect(vz.keyboards.first is VZUSBKeyboardConfiguration)
    }

    @Test("EFI scanout carries the configured display size")
    func efiScanoutMatchesConfiguration() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        var config = VMConfiguration.testLinux()
        config.displayWidth = 1680
        config.displayHeight = 1050
        let result = try ConfigurationBuilder.testing().assemble(
            from: config, bundleURL: bundleURL, validate: false)

        let graphics = try #require(
            result.configuration.graphicsDevices.first as? VZVirtioGraphicsDeviceConfiguration)
        let scanout = try #require(graphics.scanouts.first)
        #expect(scanout.widthInPixels == 1680)
        #expect(scanout.heightInPixels == 1050)
    }

    @Test("EFI guests get only the USB pointing/keyboard devices")
    func efiInputDevicesAreUSBOnly() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let result = try ConfigurationBuilder.testing().assemble(
            from: VMConfiguration.testLinux(), bundleURL: bundleURL, validate: false)
        let vz = result.configuration

        // The Mac devices are Mac-platform only, so a generic-platform guest
        // must never see them.
        #expect(vz.pointingDevices.count == 1)
        #expect(vz.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
        #expect(vz.keyboards.count == 1)
        #expect(vz.keyboards.first is VZUSBKeyboardConfiguration)
    }

    // MARK: - Socket Device

    @Test(
        "A build gives exactly the recorded shape's socket device",
        arguments: [(VMDeviceShape.current, 1), (VMDeviceShape(virtioSocketDevice: false), 0)]
    )
    func socketDeviceFollowsTheRecordedShape(shape: VMDeviceShape, socketDevices: Int) throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        var config = VMConfiguration.testLinux()
        config.deviceShape = shape

        let devices = try ConfigurationBuilder.testing()
            .assemble(from: config, bundleURL: bundleURL, validate: false)
            .configuration.socketDevices

        #expect(devices.count == socketDevices)
    }

    // MARK: - Path-Traversal Containment

    @Test("Internal storage disk path with .. escape is rejected as storageDiskNotFound")
    func internalStorageDiskRejectsPathTraversal() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Marking the entry `isInternal: true` opts into bundle-containment
        // validation. A `..` segment that resolves outside the bundle must
        // be rejected before the framework ever opens the file.
        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.storageDisks = [
            StorageDisk(
                path: "../escape/passwd",
                readOnly: true,
                label: "evil",
                isInternal: true,
                kind: .virtio
            )
        ]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskNotFound = e
            else { return false }
            return true
        }
    }

    // MARK: - Guest Agent Disk

    /// A macOS-guest config carrying `installedVersion` as its install record.
    ///
    /// `bootMode: .efi` rather than `.macOS`: the delivery decision reads
    /// `guestOS`, while the Mac boot path needs hardware-model data that only a
    /// real restore image can produce.
    private func makeAgentDiskConfig(installedVersion: String?) -> VMConfiguration {
        var config = VMConfiguration(
            name: "Test macOS", guestOS: .macOS, bootMode: .efi, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        if let installedVersion {
            config.installedImage = .macOSRestoreImage(version: installedVersion, build: "21A559")
        }
        return config
    }

    /// Writes a stand-in for the bundled installer image.
    private func makeAgentDiskImage() throws -> URL {
        let url = scratch.url.appendingPathComponent("\(UUID().uuidString).dmg")
        try Data(count: 1_048_576).write(to: url)
        return url
    }

    @Test("A guest below the USB floor gets the agent disk on virtio, attached last")
    func subFloorGuestGetsVirtioAgentDisk() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let agentURL = try makeAgentDiskImage()
        // The bring-up makes the VM's copy; the build attaches it.
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let copy = layout.guestAgentVirtioDiskURL(of: agentURL)
        try FileManager.default.createDirectory(
            at: layout.guestAgentDiskDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: agentURL, to: copy)

        let builder = ConfigurationBuilder.testing(guestAgentInstaller: agentURL)
        let result = try builder.assemble(
            from: makeAgentDiskConfig(installedVersion: "12.0.1"), bundleURL: bundleURL,
            validate: false)
        let vz = result.configuration

        #expect(vz.storageDevices.count == 2)
        let agentDevice = try #require(vz.storageDevices.last as? VZVirtioBlockDeviceConfiguration)
        let attachment = try #require(agentDevice.attachment as? VZDiskImageStorageDeviceAttachment)
        #expect(attachment.isReadOnly)
        #expect(attachment.url.standardizedFileURL == copy.standardizedFileURL)
        // The whole point of the virtio path: nothing lands on the USB bus.
        #expect(vz.usbControllers.first?.usbDevices.isEmpty == true)
    }

    @Test("The agent disk's identity is fixed by the bundle and distinct from the main disk's")
    func agentDiskIDIsStableAndDistinct() throws {
        let bundleURL = try scratch.makeEngineBundle()
        let otherBundleURL = try scratch.makeEngineBundle()

        let disk = ConfigurationBuilder.guestAgentDisk(installerPath: "/tmp/a.dmg", bundleURL: bundleURL)
        let again = ConfigurationBuilder.guestAgentDisk(installerPath: "/tmp/a.dmg", bundleURL: bundleURL)
        let other = ConfigurationBuilder.guestAgentDisk(
            installerPath: "/tmp/a.dmg", bundleURL: otherBundleURL)
        let mainDisk = StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: bundleURL))

        #expect(disk.id == again.id)
        #expect(disk.id != other.id)
        #expect(disk.id != mainDisk.id)
        // `.dmg` would otherwise default to the USB bus this delivery avoids.
        #expect(disk.kind == .virtio)
        #expect(disk.readOnly)
        #expect(!disk.isInternal)
    }

    @Test("isMainBundleDisk matches the bundle-relative path, not the disk id")
    func isMainBundleDiskMatchesByPath() throws {
        let bundleURL = try scratch.makeEngineBundle()
        let layout = VMBundleLayout(bundleURL: bundleURL)

        // A clone regenerates every disk id, so a fresh id at the canonical
        // path is still the bundle disk.
        let freshID = StorageDisk(
            id: UUID(), path: layout.diskImageURL.lastPathComponent, readOnly: false,
            label: "Main Disk", isInternal: true, kind: .virtio)
        #expect(ConfigurationBuilder.isMainBundleDisk(freshID, layout: layout))

        let additional = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        #expect(!ConfigurationBuilder.isMainBundleDisk(additional, layout: layout))

        let externalAtSameName = StorageDisk(
            path: layout.diskImageURL.path(percentEncoded: false), label: "External",
            isInternal: false)
        #expect(!ConfigurationBuilder.isMainBundleDisk(externalAtSameName, layout: layout))
    }
}
