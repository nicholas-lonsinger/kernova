import Testing
import Foundation
@testable import Kernova

@Suite("VMConfiguration Tests", .admissionGated)
struct VMConfigurationTests {
    /// Builds a complete `VMConfiguration` JSON string with all required fields populated.
    ///
    /// Pass extra comma-separated JSON fields via `extraFields` to add or override entries.
    private static func makeBaseJSON(
        name: String = "Base VM",
        extraFields: String = ""
    ) -> String {
        let extra = extraFields.isEmpty ? "" : ",\n            \(extraFields)"
        return """
            {
                "id": "12345678-1234-1234-1234-123456789012",
                "name": "\(name)",
                "guestOS": "linux",
                "bootMode": "efi",
                "cpuCount": 4,
                "memorySizeInGB": 8,
                "diskSizeInGB": 64,
                "displayWidth": 1920,
                "displayHeight": 1200,
                "displayPPI": 144,
                "displayPreference": "inline",
                "networkEnabled": true,
                "clipboardSharingEnabled": false,
                "createdAt": "2025-01-01T00:00:00Z"\(extra)
            }
            """
    }

    /// Creates a throwaway `.kernova` bundle directory containing `config.json`.
    ///
    /// Callers remove it via the returned URL in a `defer`.
    private static func makeBundle(_ configuration: VMConfiguration) throws -> URL {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(configuration.id.uuidString).kernova", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let data = try VMConfiguration.makeJSONEncoder().encode(configuration)
        try data.write(to: VMBundleLayout(bundleURL: bundleURL).configURL)
        return bundleURL
    }

    @Test("Default macOS configuration has correct defaults")
    func defaultMacOSConfig() {
        let config = VMConfiguration(
            name: "Test macOS VM",
            guestOS: .macOS,
            bootMode: .macOS
        )

        #expect(config.name == "Test macOS VM")
        #expect(config.guestOS == .macOS)
        #expect(config.bootMode == .macOS)
        #expect(config.cpuCount == VMGuestOS.macOS.defaultCPUCount)
        #expect(config.memorySizeInGB == VMGuestOS.macOS.defaultMemoryInGB)
        #expect(config.diskSizeInGB == VMGuestOS.defaultDiskSizeInGB)
        #expect(config.networkEnabled == true)
        #expect(config.displayWidth == 1920)
        #expect(config.displayHeight == 1200)
        #expect(config.displayPPI == 144)
    }

    @Test("Default Linux configuration has correct defaults")
    func defaultLinuxConfig() {
        let config = VMConfiguration(
            name: "Test Linux VM",
            guestOS: .linux,
            bootMode: .efi
        )

        #expect(config.guestOS == .linux)
        #expect(config.bootMode == .efi)
        #expect(config.cpuCount == VMGuestOS.linux.defaultCPUCount)
        #expect(config.memorySizeInGB == VMGuestOS.linux.defaultMemoryInGB)
        #expect(config.diskSizeInGB == VMGuestOS.defaultDiskSizeInGB)
    }

    @Test("Memory size in bytes is calculated correctly")
    func memorySizeInBytes() {
        let config = VMConfiguration(
            name: "Test",
            guestOS: .linux,
            bootMode: .efi,
            memorySizeInGB: 4
        )

        #expect(config.memorySizeInBytes == 4 * 1024 * 1024 * 1024)
    }

    @Test("Configuration preserves macOS-specific fields")
    func macOSSpecificFields() throws {
        let hardwareData = Data([0x01, 0x02, 0x03])
        let machineData = Data([0x04, 0x05, 0x06])

        let config = VMConfiguration(
            name: "macOS VM",
            guestOS: .macOS,
            bootMode: .macOS,
            hardwareModelData: hardwareData,
            machineIdentifierData: machineData
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: data)

        #expect(decoded.hardwareModelData == hardwareData)
        #expect(decoded.machineIdentifierData == machineData)
    }

    @Test("Configuration preserves Linux kernel fields")
    func linuxKernelFields() throws {
        let config = VMConfiguration(
            name: "Linux VM",
            guestOS: .linux,
            bootMode: .linuxKernel,
            kernelPath: "/path/to/vmlinuz",
            initrdPath: "/path/to/initrd",
            kernelCommandLine: "console=hvc0 root=/dev/vda1"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: data)

        #expect(decoded.kernelPath == "/path/to/vmlinuz")
        #expect(decoded.initrdPath == "/path/to/initrd")
        #expect(decoded.kernelCommandLine == "console=hvc0 root=/dev/vda1")
    }

    @Test("Generic machine identifier data round-trips through JSON")
    func genericMachineIdentifierRoundTrip() throws {
        let identifierData = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let config = VMConfiguration(
            name: "EFI Linux VM",
            guestOS: .linux,
            bootMode: .efi,
            genericMachineIdentifierData: identifierData
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: data)

        #expect(decoded.genericMachineIdentifierData == identifierData)
    }

    @Test("Missing optional genericMachineIdentifierData decodes as nil")
    func missingOptionalGenericMachineIdentifier() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.name == "Base VM")
        #expect(config.genericMachineIdentifierData == nil)
        #expect(config.macAddress == nil)
    }

    @Test("A config written before the drag-and-drop toggle decodes with it on")
    func missingDropFilesFlagDecodesEnabled() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.dropFilesEnabled)
        #expect(VMConfiguration(name: "New VM", guestOS: .macOS, bootMode: .macOS).dropFilesEnabled)
    }

    // MARK: - SharedDirectory Tests

    @Test("SharedDirectory encodes and decodes via JSON")
    func sharedDirectoryRoundTrip() throws {
        let original = SharedDirectory(path: "/Users/test/Documents", readOnly: true)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SharedDirectory.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.path == "/Users/test/Documents")
        #expect(decoded.readOnly == true)
    }

    @Test("SharedDirectory displayName returns last path component")
    func sharedDirectoryDisplayName() {
        let directory = SharedDirectory(path: "/Users/test/Documents/Projects")
        #expect(directory.displayName == "Projects")

        let rootDir = SharedDirectory(path: "/")
        #expect(rootDir.displayName == "/")
    }

    @Test("VMConfiguration with shared directories round-trips through JSON")
    func configWithSharedDirectoriesRoundTrip() throws {
        let directories = [
            SharedDirectory(path: "/Users/test/Shared", readOnly: false),
            SharedDirectory(path: "/Users/test/ReadOnly", readOnly: true),
        ]
        let original = VMConfiguration(
            name: "Sharing VM",
            guestOS: .linux,
            bootMode: .efi,
            sharedDirectories: directories
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.sharedDirectories?.count == 2)
        #expect(decoded.sharedDirectories?[0].path == "/Users/test/Shared")
        #expect(decoded.sharedDirectories?[0].readOnly == false)
        #expect(decoded.sharedDirectories?[1].path == "/Users/test/ReadOnly")
        #expect(decoded.sharedDirectories?[1].readOnly == true)
    }

    @Test("Configuration preserves removableMedia through JSON")
    func removableMediaRoundTrip() throws {
        let id = UUID()
        let config = VMConfiguration(
            name: "Linux VM",
            guestOS: .linux,
            bootMode: .efi,
            removableMedia: [RemovableMediaItem(id: id, path: "/Users/test/Downloads/ubuntu.iso", readOnly: true)]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        let items = try #require(decoded.removableMedia)
        #expect(items.count == 1)
        #expect(items[0].id == id)
        #expect(items[0].path == "/Users/test/Downloads/ubuntu.iso")
        #expect(items[0].readOnly == true)
    }

    @Test("Missing optional removableMedia decodes as nil")
    func missingOptionalRemovableMedia() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.removableMedia == nil)
    }

    @Test("Security bookmark fields round-trip through JSON")
    func bookmarkFieldsRoundTrip() throws {
        var original = VMConfiguration(
            name: "Bookmarked VM",
            guestOS: .linux,
            bootMode: .linuxKernel,
            kernelPath: "/boot/vmlinuz",
            initrdPath: "/boot/initrd",
            kernelBookmark: Data([0x0A]),
            initrdBookmark: Data([0x0B])
        )
        original.storageDisks = [
            StorageDisk(path: "/ext/data.img", isInternal: false, bookmark: Data([0x0C]))
        ]
        original.removableMedia = [
            RemovableMediaItem(path: "/ext/install.iso", bookmark: Data([0x0D]))
        ]
        original.sharedDirectories = [
            SharedDirectory(path: "/Users/me/Shared", bookmark: Data([0x0E]))
        ]

        let data = try VMConfiguration.makeJSONEncoder().encode(original)
        let decoded = try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)

        #expect(decoded.kernelBookmark == Data([0x0A]))
        #expect(decoded.initrdBookmark == Data([0x0B]))
        #expect(decoded.storageDisks?[0].bookmark == Data([0x0C]))
        #expect(decoded.removableMedia?[0].bookmark == Data([0x0D]))
        #expect(decoded.sharedDirectories?[0].bookmark == Data([0x0E]))
    }

    @Test("Pre-sandbox JSON without bookmark fields decodes with nil bookmarks")
    func missingBookmarkFieldsDecodeNil() throws {
        // The exact shape written by pre-sandbox builds: raw paths only.
        let json = Self.makeBaseJSON(
            extraFields: """
                "kernelPath": "/boot/vmlinuz",
                "storageDisks": [{"id": "22345678-1234-1234-1234-123456789012", "path": "/ext/d.img", "readOnly": false, "label": "D", "isInternal": false, "kind": "virtio"}],
                "removableMedia": [{"id": "32345678-1234-1234-1234-123456789012", "path": "/ext/i.iso", "readOnly": true, "label": "I"}],
                "sharedDirectories": [{"id": "42345678-1234-1234-1234-123456789012", "path": "/Users/me/S", "readOnly": false}]
                """
        )
        let decoded = try VMConfiguration.makeJSONDecoder().decode(
            VMConfiguration.self, from: Data(json.utf8))

        #expect(decoded.kernelPath == "/boot/vmlinuz")
        #expect(decoded.kernelBookmark == nil)
        #expect(decoded.initrdBookmark == nil)
        #expect(decoded.storageDisks?[0].bookmark == nil)
        #expect(decoded.removableMedia?[0].bookmark == nil)
        #expect(decoded.sharedDirectories?[0].bookmark == nil)
    }

    @Test("Missing optional sharedDirectories decodes as nil")
    func missingOptionalSharedDirectories() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.sharedDirectories == nil)
    }

    @Test("serialSocketRelayEnabled round-trips through JSON")
    func serialSocketRelayEnabledRoundTrip() throws {
        var original = VMConfiguration(name: "Relay VM", guestOS: .linux, bootMode: .efi)
        original.serialSocketRelayEnabled = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: try encoder.encode(original))

        #expect(decoded.serialSocketRelayEnabled == true)
    }

    @Test("Missing serialSocketRelayEnabled decodes as false")
    func missingSerialSocketRelayEnabledDefaultsFalse() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.serialSocketRelayEnabled == false)
    }

    // MARK: - Launch Auto-Start

    @Test("startsAutomaticallyOnLaunch round-trips through JSON")
    func startsAutomaticallyOnLaunchRoundTrip() throws {
        var original = VMConfiguration(name: "Auto VM", guestOS: .linux, bootMode: .efi)
        original.startsAutomaticallyOnLaunch = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: try encoder.encode(original))

        #expect(decoded.startsAutomaticallyOnLaunch == true)
    }

    @Test("Missing startsAutomaticallyOnLaunch decodes as false")
    func missingStartsAutomaticallyOnLaunchDefaultsFalse() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.startsAutomaticallyOnLaunch == false)
    }

    @Test("A new configuration does not start automatically")
    func newConfigurationDoesNotStartAutomatically() {
        let config = VMConfiguration(name: "Fresh VM", guestOS: .linux, bootMode: .efi)

        #expect(config.startsAutomaticallyOnLaunch == false)
    }

    // MARK: - Port Forwarding

    @Test("Port forwarding rules round-trip through JSON")
    func portForwardingRulesRoundTrip() throws {
        var original = VMConfiguration(name: "Forwarding VM", guestOS: .linux, bootMode: .efi)
        original.portForwardingRules = [
            PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80),
            PortForwardingRule(transport: .udp, hostPort: 5353, guestPort: 53),
        ]

        let decoded = try VMConfiguration.makeJSONDecoder()
            .decode(VMConfiguration.self, from: VMConfiguration.makeJSONEncoder().encode(original))

        #expect(decoded.portForwardingRules == original.portForwardingRules)
    }

    @Test("Missing portForwardingRules decodes as none")
    func missingPortForwardingRulesDefaultsEmpty() throws {
        let config = try VMConfiguration.makeJSONDecoder()
            .decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.portForwardingRules.isEmpty)
    }

    @Test("A clone starts with no forwarding rules of its own")
    func cloneDropsPortForwardingRules() {
        var config = VMConfiguration(name: "Forwarding VM", guestOS: .linux, bootMode: .efi)
        config.portForwardingRules = [
            PortForwardingRule(transport: .tcp, hostPort: 2222, guestPort: 22)
        ]

        let clone = config.clonedForNewInstance(existingNames: [])

        // Carried over, the clone's rules would claim host ports the source
        // already holds on the same network.
        #expect(clone.portForwardingRules.isEmpty)
        #expect(config.portForwardingRules.count == 1)
    }

    @Test("Unknown JSON keys are silently ignored")
    func unknownKeysIgnored() throws {
        let json = Self.makeBaseJSON(
            extraFields: "\"notes\": \"These are old notes that should be ignored\""
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(json.utf8))

        #expect(config.guestOS == .linux)
    }

    @Test("VMConfiguration with nil shared directories omits field from JSON")
    func nilSharedDirectoriesOmittedFromJSON() throws {
        let config = VMConfiguration(
            name: "No Shares",
            guestOS: .macOS,
            bootMode: .macOS
        )

        let data = try JSONEncoder().encode(config)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(jsonObject["sharedDirectories"] == nil)
    }

    @Test("SharedDirectory defaults to read-write")
    func sharedDirectoryDefaultReadOnly() {
        let directory = SharedDirectory(path: "/tmp/test")
        #expect(directory.readOnly == false)
    }

    // MARK: - StorageDisk Tests

    @Test("StorageDisk blockDeviceIdentifier fits within 20 characters")
    func storageDiskBlockDeviceIdentifierLength() {
        let disk = StorageDisk(path: "/tmp/data.asif")
        #expect(disk.blockDeviceIdentifier.count <= 20)
        #expect(!disk.blockDeviceIdentifier.isEmpty)
    }

    @Test("StorageDisk auto-generates label from filename")
    func storageDiskAutoLabel() {
        let disk = StorageDisk(path: "/Users/test/Downloads/my-data.asif")
        #expect(disk.label == "my-data")
    }

    @Test("StorageDisk default readOnly is false")
    func storageDiskDefaultReadOnly() {
        let disk = StorageDisk(path: "/tmp/test.asif")
        #expect(disk.readOnly == false)
    }

    @Test("StorageDisk default isInternal is false")
    func storageDiskDefaultIsInternal() {
        let disk = StorageDisk(path: "/tmp/test.asif")
        #expect(disk.isInternal == false)
    }

    @Test("StorageDisk default kind is inferred from extension")
    func storageDiskDefaultKindFromExtension() {
        #expect(StorageDisk(path: "/tmp/Disk.asif").kind == .virtio)
        #expect(StorageDisk(path: "/tmp/installer.iso").kind == .usbMassStorage)
        #expect(StorageDisk(path: "/tmp/installer.dmg").kind == .usbMassStorage)
    }

    @Test("Configuration round-trips storageDisks")
    func storageDisksRoundTrip() throws {
        let config = VMConfiguration(
            name: "Multi-Disk VM",
            guestOS: .linux,
            bootMode: .efi,
            storageDisks: [
                StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
                StorageDisk(path: "/tmp/data.asif", readOnly: false, label: "Data", isInternal: false, kind: .virtio),
                StorageDisk(
                    path: "/tmp/installer.iso", readOnly: true, label: "Installer", isInternal: false,
                    kind: .usbMassStorage),
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        let disks = decoded.storageDisks ?? []
        #expect(disks.count == 3)
        #expect(disks.first?.label == "Main Disk")
        #expect(disks.first?.isInternal == true)
        #expect(disks.first?.kind == .virtio)
        if disks.count >= 3 {
            #expect(disks[2].label == "Installer")
            #expect(disks[2].kind == .usbMassStorage)
            #expect(disks[2].readOnly == true)
        }
    }

    @Test("Missing optional storageDisks decodes as nil")
    func missingOptionalStorageDisks() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.storageDisks == nil)
    }

    @Test("Clone regenerates storageDisk IDs")
    func cloneRegeneratesStorageDiskIDs() {
        let originalDisk = StorageDisk(path: "/tmp/data.asif", label: "Data")
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi,
            storageDisks: [originalDisk]
        )

        let clone = config.clonedForNewInstance(existingNames: [])

        #expect(clone.storageDisks?.count == 1)
        #expect(clone.storageDisks?[0].id != originalDisk.id)
        #expect(clone.storageDisks?[0].path == originalDisk.path)
        #expect(clone.storageDisks?[0].label == originalDisk.label)
    }

    @Test("StorageDisk.uniqueLabel returns base when there's no collision")
    func uniqueLabelNoCollision() {
        #expect(StorageDisk.uniqueLabel(base: "100 GB Disk", existingLabels: []) == "100 GB Disk")
        #expect(
            StorageDisk.uniqueLabel(base: "100 GB Disk", existingLabels: ["Main Disk"])
                == "100 GB Disk")
    }

    @Test("StorageDisk.uniqueLabel suffixes to the next free number on collision")
    func uniqueLabelCollision() {
        #expect(
            StorageDisk.uniqueLabel(base: "100 GB Disk", existingLabels: ["100 GB Disk"])
                == "100 GB Disk 2")
        #expect(
            StorageDisk.uniqueLabel(
                base: "100 GB Disk",
                existingLabels: ["100 GB Disk", "100 GB Disk 2", "100 GB Disk 3"])
                == "100 GB Disk 4")
    }

    @Test("StorageDisk.uniqueLabel is case-sensitive")
    func uniqueLabelCaseSensitive() {
        // A differently-cased existing label is not treated as a collision.
        #expect(StorageDisk.uniqueLabel(base: "Disk", existingLabels: ["disk"]) == "Disk")
    }

    // MARK: - installContext Tests

    @Test("installContext round-trips through JSON (downloadLatest)")
    func installContextDownloadLatestRoundTrip() throws {
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: "/Users/me/Downloads/RestoreImage.ipsw"
        )
        let config = VMConfiguration(
            name: "Pending macOS VM",
            guestOS: .macOS,
            bootMode: .macOS,
            installContext: context
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.installContext == context)
        #expect(decoded.installContext?.source == .downloadLatest)
        #expect(decoded.installContext?.downloadDestinationPath == "/Users/me/Downloads/RestoreImage.ipsw")
    }

    @Test("installContext round-trips through JSON (localFile)")
    func installContextLocalFileRoundTrip() throws {
        let context = MacOSInstallContext(
            source: .localFile,
            localIPSWPath: "/tmp/macOS-26.ipsw"
        )
        let config = VMConfiguration(
            name: "Local IPSW VM",
            guestOS: .macOS,
            bootMode: .macOS,
            installContext: context
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.installContext == context)
        #expect(decoded.installContext?.source == .localFile)
        #expect(decoded.installContext?.localIPSWPath == "/tmp/macOS-26.ipsw")
    }

    @Test("A config omitting installContext decodes it as nil")
    func configOmittingInstallContextDecodesNil() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.installContext == nil)
    }

    @Test("VMConfiguration with nil installContext omits field from JSON")
    func nilInstallContextOmittedFromJSON() throws {
        let config = VMConfiguration(
            name: "Plain VM",
            guestOS: .linux,
            bootMode: .efi
        )

        let data = try JSONEncoder().encode(config)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(jsonObject["installContext"] == nil)
    }

    // MARK: - linuxInstallContext Tests

    @Test("linuxInstallContext round-trips through JSON")
    func linuxInstallContextRoundTrip() throws {
        let context = LinuxInstallContext(
            source: .catalogEntry(makeLinuxCatalogEntry()),
            downloadDestinationPath: "/Users/me/Downloads/debian-13.6.0-arm64-netinst.iso"
        )
        let config = VMConfiguration(
            name: "Pending Debian VM",
            guestOS: .linux,
            bootMode: .efi,
            linuxInstallContext: context
        )

        let data = try VMConfiguration.makeJSONEncoder().encode(config)
        let decoded = try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)

        #expect(decoded.linuxInstallContext == context)
        #expect(catalogEntry(of: decoded.linuxInstallContext)?.id == "debian-13")
        #expect(
            decoded.linuxInstallContext?.downloadDestinationPath
                == "/Users/me/Downloads/debian-13.6.0-arm64-netinst.iso")
        // The two contexts are separate fields, and each guest uses only its own.
        #expect(decoded.installContext == nil)
    }

    @Test("A config.json without linuxInstallContext decodes as nil")
    func configWithoutLinuxInstallContextDecodesAsNil() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.linuxInstallContext == nil)
    }

    @Test("VMConfiguration with nil linuxInstallContext omits field from JSON")
    func nilLinuxInstallContextOmittedFromJSON() throws {
        let config = VMConfiguration(name: "Plain VM", guestOS: .linux, bootMode: .efi)

        let data = try JSONEncoder().encode(config)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(jsonObject["linuxInstallContext"] == nil)
    }

    @Test("An installContext omitting requestedFreshDownload decodes it as false")
    func installContextOmittingRequestedFreshDownloadDecodesFalse() throws {
        let baseFields = """
            "installContext": {
                "source": "downloadLatest",
                "downloadDestinationPath": "/Users/me/Downloads/RestoreImage.ipsw"
            }
            """
        let json = Self.makeBaseJSON(extraFields: baseFields)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(json.utf8))

        #expect(config.installContext?.source == .downloadLatest)
        #expect(
            config.installContext?.downloadDestinationPath
                == "/Users/me/Downloads/RestoreImage.ipsw"
        )
        #expect(config.installContext?.requestedFreshDownload == false)
    }

    @Test("Clone clears installContext even when source has one set")
    func cloneClearsInstallContext() {
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: "/tmp/RestoreImage.ipsw"
        )
        let config = VMConfiguration(
            name: "Pending macOS VM",
            guestOS: .macOS,
            bootMode: .macOS,
            installContext: context
        )

        let clone = config.clonedForNewInstance(existingNames: [])

        #expect(clone.installContext == nil)
    }

    // MARK: - displayPreference Tests

    @Test("Default displayPreference is inline")
    func defaultDisplayPreference() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        #expect(config.displayPreference == .inline)
    }

    @Test("Configuration preserves displayPreference")
    func displayPreferenceRoundTrip() throws {
        let config = VMConfiguration(
            name: "Fullscreen VM",
            guestOS: .linux,
            bootMode: .efi,
            displayPreference: .fullscreen
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.displayPreference == .fullscreen)
    }

    @Test("displayPreference round-trips popOut value")
    func displayPreferencePopOutRoundTrip() throws {
        let config = VMConfiguration(
            name: "PopOut VM",
            guestOS: .linux,
            bootMode: .efi,
            displayPreference: .popOut
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.displayPreference == .popOut)
    }

    // MARK: - displaySizesToWindow / displayHiDPI / displayAutoResizes Tests

    @Test("Display sizing defaults: match-window on, HiDPI on, auto-resize on")
    func defaultDisplaySizingFlags() {
        let config = VMConfiguration(name: "Test VM", guestOS: .macOS, bootMode: .macOS)
        #expect(config.displaySizesToWindow == true)
        #expect(config.displayHiDPI == true)
        #expect(config.displayAutoResizes == true)
    }

    @Test("Configuration round-trips the display sizing flags")
    func displaySizingFlagsRoundTrip() throws {
        let config = VMConfiguration(
            name: "Sizing VM",
            guestOS: .macOS,
            bootMode: .macOS,
            displaySizesToWindow: false,
            displayHiDPI: false,
            displayAutoResizes: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.displaySizesToWindow == false)
        #expect(decoded.displayHiDPI == false)
        #expect(decoded.displayAutoResizes == false)
    }

    @Test("Missing display sizing keys decode to the on defaults")
    func missingDisplaySizingKeysUseDefaults() throws {
        // `makeBaseJSON` carries none of the three keys.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.displaySizesToWindow == true)
        #expect(config.displayHiDPI == true)
        #expect(config.displayAutoResizes == true)
    }

    @Test("displayResolution reads and writes the stored trio")
    func displayResolutionAccessesTheTrio() {
        var config = VMConfiguration(
            name: "Test VM", guestOS: .macOS, bootMode: .macOS,
            displayWidth: 2560, displayHeight: 1600, displayPPI: 220)
        #expect(config.displayResolution == DisplayBootSizing.Resolution(width: 2560, height: 1600, ppi: 220))

        config.displayResolution = DisplayBootSizing.Resolution(width: 1280, height: 800, ppi: 144)
        #expect(config.displayWidth == 1280)
        #expect(config.displayHeight == 800)
        #expect(config.displayPPI == 144)
    }

    // MARK: - lastFullscreenDisplayID Tests

    @Test("Default lastFullscreenDisplayID is nil")
    func defaultLastFullscreenDisplayID() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        #expect(config.lastFullscreenDisplayID == nil)
    }

    @Test("Configuration preserves lastFullscreenDisplayID")
    func lastFullscreenDisplayIDRoundTrip() throws {
        let config = VMConfiguration(
            name: "Display VM",
            guestOS: .linux,
            bootMode: .efi,
            lastFullscreenDisplayID: 4_280_803_137
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.lastFullscreenDisplayID == 4_280_803_137)
    }

    @Test("Missing optional lastFullscreenDisplayID decodes as nil")
    func missingOptionalLastFullscreenDisplayID() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.lastFullscreenDisplayID == nil)
    }

    // MARK: - clipboardSharingEnabled Tests

    @Test("Default clipboardSharingEnabled is false")
    func defaultClipboardSharingEnabled() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        #expect(config.clipboardSharingEnabled == false)
    }

    @Test("Configuration preserves clipboardSharingEnabled flag")
    func clipboardSharingEnabledRoundTrip() throws {
        let config = VMConfiguration(
            name: "Clipboard VM",
            guestOS: .linux,
            bootMode: .efi,
            clipboardSharingEnabled: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.clipboardSharingEnabled == true)
    }

    // MARK: - clipboardPassthroughEnabled Tests

    @Test("Default clipboardPassthroughEnabled is false")
    func defaultClipboardPassthroughEnabled() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .macOS,
            bootMode: .macOS
        )
        #expect(config.clipboardPassthroughEnabled == false)
    }

    @Test("Configuration preserves clipboardPassthroughEnabled flag")
    func clipboardPassthroughEnabledRoundTrip() throws {
        let config = VMConfiguration(
            name: "Passthrough VM",
            guestOS: .macOS,
            bootMode: .macOS,
            clipboardPassthroughEnabled: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.clipboardPassthroughEnabled == true)
    }

    @Test("Configs missing the clipboardPassthroughEnabled key default it off")
    func clipboardPassthroughMissingKeyUsesDefault() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(decoded.clipboardPassthroughEnabled == false)
    }

    // MARK: - agentLogForwardingEnabled Tests

    @Test("Default agentLogForwardingEnabled is false")
    func defaultAgentLogForwardingEnabled() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .macOS,
            bootMode: .macOS
        )
        #expect(config.agentLogForwardingEnabled == false)
    }

    @Test("Configuration preserves agentLogForwardingEnabled flag")
    func agentLogForwardingEnabledRoundTrip() throws {
        let config = VMConfiguration(
            name: "Logging VM",
            guestOS: .macOS,
            bootMode: .macOS,
            agentLogForwardingEnabled: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.agentLogForwardingEnabled == true)
    }

    @Test("A config omitting agentLogForwardingEnabled decodes it as false")
    func missingAgentLogForwardingEnabledDecodesFalse() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.agentLogForwardingEnabled == false)
    }

    // MARK: - lastSeenAgentVersion Tests

    @Test("Default lastSeenAgentVersion is nil")
    func defaultLastSeenAgentVersion() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .macOS,
            bootMode: .macOS
        )
        #expect(config.lastSeenAgentVersion == nil)
    }

    @Test("Configuration round-trips lastSeenAgentVersion")
    func lastSeenAgentVersionRoundTrip() throws {
        let config = VMConfiguration(
            name: "Persisted VM",
            guestOS: .macOS,
            bootMode: .macOS,
            lastSeenAgentVersion: "0.9.2"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.lastSeenAgentVersion == "0.9.2")
    }

    @Test("A config omitting lastSeenAgentVersion decodes it as nil")
    func missingLastSeenAgentVersionDecodesNil() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.lastSeenAgentVersion == nil)
    }

    // MARK: - lastSeenGuestOSVersion Tests

    @Test("Default lastSeenGuestOSVersion is nil")
    func defaultLastSeenGuestOSVersion() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .macOS,
            bootMode: .macOS
        )
        #expect(config.lastSeenGuestOSVersion == nil)
    }

    @Test("Configuration round-trips lastSeenGuestOSVersion")
    func lastSeenGuestOSVersionRoundTrip() throws {
        let config = VMConfiguration(
            name: "Persisted VM",
            guestOS: .macOS,
            bootMode: .macOS,
            lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.lastSeenGuestOSVersion == "Version 26.0 (Build 25A123)")
    }

    @Test("A config omitting lastSeenGuestOSVersion decodes it as nil")
    func missingLastSeenGuestOSVersionDecodesNil() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.lastSeenGuestOSVersion == nil)
    }

    // MARK: - installedImage Tests

    @Test("Default installedImage is nil")
    func defaultInstalledImage() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .macOS,
            bootMode: .macOS
        )
        #expect(config.installedImage == nil)
    }

    @Test("Configuration round-trips a macOS installedImage")
    func macOSInstalledImageRoundTrip() throws {
        let config = VMConfiguration(
            name: "Persisted VM",
            guestOS: .macOS,
            bootMode: .macOS,
            installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84")
        )

        let decoded = try VMConfiguration.makeJSONDecoder().decode(
            VMConfiguration.self, from: VMConfiguration.makeJSONEncoder().encode(config))

        #expect(decoded.installedImage == .macOSRestoreImage(version: "26.5.2", build: "25F84"))
    }

    @Test("Configuration round-trips a Linux installedImage")
    func linuxInstalledImageRoundTrip() throws {
        let config = VMConfiguration(
            name: "Persisted VM",
            guestOS: .linux,
            bootMode: .efi,
            installedImage: .linuxCatalogImage(distribution: "Ubuntu Desktop", version: "26.04 LTS")
        )

        let decoded = try VMConfiguration.makeJSONDecoder().decode(
            VMConfiguration.self, from: VMConfiguration.makeJSONEncoder().encode(config))

        #expect(
            decoded.installedImage
                == .linuxCatalogImage(distribution: "Ubuntu Desktop", version: "26.04 LTS"))
    }

    @Test("A config omitting installedImage decodes it as nil")
    func missingInstalledImageDecodesNil() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.installedImage == nil)
    }

    // MARK: - agentInstallNudgeDismissed Tests

    @Test("Default agentInstallNudgeDismissed is false")
    func defaultAgentInstallNudgeDismissed() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .macOS,
            bootMode: .macOS
        )
        #expect(config.agentInstallNudgeDismissed == false)
    }

    @Test("Configuration round-trips agentInstallNudgeDismissed")
    func agentInstallNudgeDismissedRoundTrip() throws {
        let config = VMConfiguration(
            name: "Dismissed VM",
            guestOS: .macOS,
            bootMode: .macOS,
            agentInstallNudgeDismissed: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.agentInstallNudgeDismissed == true)
    }

    @Test("A config omitting agentInstallNudgeDismissed decodes it as false")
    func missingAgentInstallNudgeDismissedDecodesFalse() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.agentInstallNudgeDismissed == false)
    }

    // MARK: - Audio Tests

    @Test("audioInputEnabled defaults to false and audioOutputEnabled defaults to true")
    func audioDefaults() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        #expect(config.audioInputEnabled == false)
        #expect(config.audioOutputEnabled == true)
    }

    @Test("Configuration preserves audio input/output flags")
    func audioFlagsRoundTrip() throws {
        let config = VMConfiguration(
            name: "Audio VM",
            guestOS: .linux,
            bootMode: .efi,
            audioInputEnabled: true,
            audioOutputEnabled: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.audioInputEnabled == true)
        #expect(decoded.audioOutputEnabled == false)
    }

    @Test("Configs missing both audio keys default input off, output on")
    func audioKeysMissingUseDefaults() throws {
        // `makeBaseJSON` carries neither `audioInputEnabled` nor
        // `audioOutputEnabled` — the shape of a config saved before the audio
        // keys existed. Both must fall through to their defaults.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(decoded.audioInputEnabled == false)
        #expect(decoded.audioOutputEnabled == true)
    }

    // MARK: - Network Mode Tests

    @Test("networkMode defaults to shared with no bridged interface")
    func networkModeDefaults() {
        let config = VMConfiguration(name: "Test VM", guestOS: .linux, bootMode: .efi)
        #expect(config.networkMode == .shared)
        #expect(config.bridgedInterfaceIdentifier == nil)
    }

    @Test("networkChoice maps the persisted fields and is nil without a device")
    func networkChoiceMapsPersistedFields() {
        var config = VMConfiguration(name: "Test VM", guestOS: .linux, bootMode: .efi)
        config.networkMode = .bridged
        config.bridgedInterfaceIdentifier = "en0"
        #expect(
            config.networkChoice
                == NetworkChoice(mode: .bridged, bridgedInterfaceIdentifier: "en0"))

        config.networkEnabled = false
        #expect(config.networkChoice == nil)
    }

    @Test("A config carrying neither network key decodes as Shared Network")
    func networkModeKeysMissingUseDefaults() throws {
        // `makeBaseJSON` carries `networkEnabled` but neither mode key.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(decoded.networkEnabled == true)
        #expect(decoded.networkMode == .shared)
        #expect(decoded.bridgedInterfaceIdentifier == nil)
    }

    @Test("Configuration preserves a bridged mode and its interface")
    func bridgedModeRoundTrip() throws {
        let config = VMConfiguration(
            name: "Bridged VM",
            guestOS: .linux,
            bootMode: .efi,
            networkMode: .bridged,
            bridgedInterfaceIdentifier: "en0"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.networkMode == .bridged)
        #expect(decoded.bridgedInterfaceIdentifier == "en0")
    }

    @Test("Configuration preserves the host-only mode")
    func hostOnlyModeRoundTrip() throws {
        let config = VMConfiguration(
            name: "Host Only VM",
            guestOS: .linux,
            bootMode: .efi,
            networkMode: .hostOnly
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.networkMode == .hostOnly)
        #expect(decoded.networkChoice == NetworkChoice(mode: .hostOnly, bridgedInterfaceIdentifier: nil))
    }

    @Test("A host-only config decodes from the stored raw value")
    func hostOnlyModeDecodesFromRawValue() throws {
        let json = Self.makeBaseJSON(extraFields: "\"networkMode\": \"hostOnly\"")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: Data(json.utf8))

        #expect(decoded.networkMode == .hostOnly)
    }

    @Test("A bridged config decodes Automatic from a stored mode without an interface")
    func bridgedModeWithoutInterfaceDecodesAutomatic() throws {
        let json = Self.makeBaseJSON(extraFields: "\"networkMode\": \"bridged\"")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: Data(json.utf8))

        #expect(decoded.networkMode == .bridged)
        #expect(decoded.bridgedInterfaceIdentifier == nil)
    }

    // MARK: - Input Device Mode Tests

    @Test("inputDeviceMode defaults to automatic, in the initializer and on a missing key")
    func inputDeviceModeDefaults() throws {
        let config = VMConfiguration(name: "Test VM", guestOS: .macOS, bootMode: .macOS)
        #expect(config.inputDeviceMode == .automatic)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))
        #expect(decoded.inputDeviceMode == .automatic)
    }

    @Test("Configuration preserves an explicit input device mode")
    func inputDeviceModeRoundTrip() throws {
        var config = VMConfiguration(name: "Test VM", guestOS: .macOS, bootMode: .macOS)
        config.inputDeviceMode = .usb

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)
        #expect(decoded.inputDeviceMode == .usb)
    }

    // MARK: - Full-field round-trip

    /// Populates every property with a non-default value, encodes to JSON,
    /// decodes back, and asserts equality.
    ///
    /// Tripwire for the custom
    /// `init(from:)`: if a new field is added to `VMConfiguration` but the
    /// decoder is not updated, the missed field will silently default-
    /// initialize on decode and the round-trip equality will fail.
    ///
    /// When this test fires, also update `init(from:)` in `VMConfiguration`
    /// to read the new key.
    @Test("Configuration with all fields populated round-trips identically through JSON")
    func fullFieldRoundTrip() throws {
        let original = VMConfiguration(
            id: UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!,
            name: "Comprehensive VM",
            guestOS: .macOS,
            bootMode: .macOS,
            startsAutomaticallyOnLaunch: true,
            cpuCount: 12,
            memorySizeInGB: 24,
            diskSizeInGB: 256,
            displayWidth: 2560,
            displayHeight: 1440,
            displayPPI: 192,
            displaySizesToWindow: false,
            displayHiDPI: false,
            displayAutoResizes: false,
            displayPreference: .popOut,
            lastFullscreenDisplayID: 0xDEAD_BEEF,
            networkEnabled: false,
            networkMode: .bridged,
            bridgedInterfaceIdentifier: "en1",
            macAddress: "aa:bb:cc:dd:ee:ff",
            clipboardSharingEnabled: true,
            clipboardPassthroughEnabled: true,
            serialSocketRelayEnabled: true,
            audioInputEnabled: true,
            audioOutputEnabled: false,
            agentLogForwardingEnabled: true,
            lastSeenAgentVersion: "1.2.3",
            hardwareModelData: Data([0x01, 0x02, 0x03]),
            machineIdentifierData: Data([0x04, 0x05]),
            genericMachineIdentifierData: Data([0x06]),
            kernelPath: "/path/to/kernel",
            initrdPath: "/path/to/initrd",
            kernelCommandLine: "console=ttyS0",
            storageDisks: [
                StorageDisk(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    path: "Disk.asif",
                    readOnly: false,
                    label: "Main Disk",
                    isInternal: true,
                    kind: .virtio
                ),
                StorageDisk(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    path: "/disk2.img",
                    readOnly: true,
                    label: "data",
                    isInternal: false,
                    kind: .virtio
                ),
            ],
            removableMedia: [
                RemovableMediaItem(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    path: "/path/to/disk.iso",
                    readOnly: false,
                    label: "Installer"
                )
            ],
            sharedDirectories: [
                SharedDirectory(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    path: "/host/shared",
                    readOnly: true
                )
            ],
            // Whole-second timestamp so .iso8601 (no fractional seconds)
            // round-trips without precision loss.
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(
            decoded == original,
            "Round-trip mismatch — likely an unhandled field in `init(from:)`"
        )
    }

    // MARK: - Missing Required Fields

    @Test("Decoding JSON missing a required field throws DecodingError")
    func missingRequiredFieldThrows() {
        // Intentionally omits the required fields displayPreference and
        // clipboardSharingEnabled. (The audio keys are optional and default, so
        // their absence alone would not throw.)
        let json = """
            {
                "id": "12345678-1234-1234-1234-123456789012",
                "name": "Incomplete VM",
                "guestOS": "linux",
                "bootMode": "efi",
                "cpuCount": 4,
                "memorySizeInGB": 8,
                "diskSizeInGB": 64,
                "displayWidth": 1920,
                "displayHeight": 1200,
                "displayPPI": 144,
                "networkEnabled": true,
                "createdAt": "2025-01-01T00:00:00Z"
            }
            """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(VMConfiguration.self, from: Data(json.utf8))
        }
    }

    // MARK: - Removable Media Changes

    @Test("removableMediaChanged detects a readOnly flip on an existing item")
    func removableMediaChangedDetectsReadOnlyFlip() {
        let id = UUID()
        var base = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        base.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        var modified = base
        modified.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: false)]
        #expect(VMConfiguration.removableMediaChanged(old: base, new: modified))
    }

    @Test("removableMediaChanged ignores storageDisks changes")
    func removableMediaChangedIgnoresStorageDisks() {
        // Storage disks are restart-only on VZ (storageDevices is fixed at
        // VM start). The live reconcile flow only acts on removableMedia.
        let base = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        var modified = base
        modified.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio)
        ]
        #expect(!VMConfiguration.removableMediaChanged(old: base, new: modified))
    }

    @Test("removableMediaChanged detects list mutations")
    func removableMediaChangedDetectsMutations() {
        let base = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        var added = base
        added.removableMedia = [RemovableMediaItem(path: "/tmp/install.iso", readOnly: true)]
        #expect(VMConfiguration.removableMediaChanged(old: base, new: added))
        #expect(VMConfiguration.removableMediaChanged(old: added, new: base))
        #expect(!VMConfiguration.removableMediaChanged(old: base, new: base))
        #expect(!VMConfiguration.removableMediaChanged(old: added, new: added))
    }

    // MARK: - Bundle loading seam

    @Test("VMConfiguration.load(fromBundle:) round-trips the saved config")
    func loadFromBundleRoundTrip() throws {
        // Whole-second creation date: the ISO-8601 strategy drops fractional
        // seconds, which would break exact equality after the round trip.
        let config = VMConfiguration(
            name: "Round Trip", guestOS: .linux, bootMode: .efi, cpuCount: 4,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        let bundleURL = try Self.makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let loaded = try VMConfiguration.load(fromBundle: bundleURL)
        #expect(loaded == config)
    }

    @Test("VMConfiguration.load(fromBundle:) throws when config.json is absent")
    func loadFromBundleMissingConfig() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).kernova", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        #expect(throws: (any Error).self) {
            try VMConfiguration.load(fromBundle: bundleURL)
        }
    }
}
