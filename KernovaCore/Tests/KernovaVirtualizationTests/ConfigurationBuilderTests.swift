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

    // MARK: - Removable Media

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
