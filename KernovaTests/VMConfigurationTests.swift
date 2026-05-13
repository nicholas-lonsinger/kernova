import Testing
import Foundation
@testable import Kernova

@Suite("VMConfiguration Tests")
struct VMConfigurationTests {
    /// Builds a complete `VMConfiguration` JSON string with all required fields populated.
    ///
    /// Pass extra comma-separated JSON fields via `extraFields` to add or override entries.
    private static func makeBaseJSON(
        name: String = "Old VM",
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
                "microphoneEnabled": false,
                "createdAt": "2025-01-01T00:00:00Z"\(extra)
            }
            """
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
        #expect(config.diskSizeInGB == VMGuestOS.macOS.defaultDiskSizeInGB)
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
        #expect(config.diskSizeInGB == VMGuestOS.linux.defaultDiskSizeInGB)
    }

    @Test("Configuration encodes and decodes via JSON")
    func codableRoundTrip() throws {
        let original = VMConfiguration(
            name: "Roundtrip VM",
            guestOS: .macOS,
            bootMode: .macOS,
            cpuCount: 8,
            memorySizeInGB: 16,
            diskSizeInGB: 200
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.guestOS == original.guestOS)
        #expect(decoded.bootMode == original.bootMode)
        #expect(decoded.cpuCount == original.cpuCount)
        #expect(decoded.memorySizeInGB == original.memorySizeInGB)
        #expect(decoded.diskSizeInGB == original.diskSizeInGB)
        #expect(decoded.networkEnabled == original.networkEnabled)
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

        #expect(config.name == "Old VM")
        #expect(config.genericMachineIdentifierData == nil)
        #expect(config.macAddress == nil)
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

    @Test("Missing optional sharedDirectories decodes as nil")
    func missingOptionalSharedDirectories() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.sharedDirectories == nil)
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

    @Test("Missing agentLogForwardingEnabled decodes as false (existing-VM migration)")
    func missingAgentLogForwardingEnabledDecodesFalse() throws {
        // Older configs predate the field — they must still decode, with the
        // new flag defaulting to off so existing VMs don't suddenly forward
        // logs without the user opting in.
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

    @Test("Missing lastSeenAgentVersion decodes as nil (existing-VM migration)")
    func missingLastSeenAgentVersionDecodesNil() throws {
        // Older configs predate the field — they must still decode, with the
        // optional defaulting to nil so the post-start watchdog doesn't
        // misfire on VMs that have never connected an agent.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.lastSeenAgentVersion == nil)
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

    @Test("Missing agentInstallNudgeDismissed decodes as false (existing-VM migration)")
    func missingAgentInstallNudgeDismissedDecodesFalse() throws {
        // Older configs predate the field — they must still decode, with the
        // flag defaulting to off so the install nudge keeps surfacing for
        // VMs the user has never actively dismissed.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.agentInstallNudgeDismissed == false)
    }

    // MARK: - microphoneEnabled Tests

    @Test("Default microphoneEnabled is false")
    func defaultMicrophoneEnabled() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        #expect(config.microphoneEnabled == false)
    }

    @Test("Configuration preserves microphoneEnabled flag")
    func microphoneEnabledRoundTrip() throws {
        let config = VMConfiguration(
            name: "Mic VM",
            guestOS: .linux,
            bootMode: .efi,
            microphoneEnabled: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.microphoneEnabled == true)
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
            cpuCount: 12,
            memorySizeInGB: 24,
            diskSizeInGB: 256,
            displayWidth: 2560,
            displayHeight: 1440,
            displayPPI: 192,
            displayPreference: .popOut,
            lastFullscreenDisplayID: 0xDEAD_BEEF,
            networkEnabled: false,
            macAddress: "aa:bb:cc:dd:ee:ff",
            clipboardSharingEnabled: true,
            microphoneEnabled: true,
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
                    path: "/path/to/disc.iso",
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
        // Intentionally omits: displayPreference, clipboardSharingEnabled,
        // microphoneEnabled
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

    // MARK: - Live-Editable Fields

    @Test("liveEditableFieldsChanged detects added removable media item")
    func liveEditableDetectsAddedRemovableMedia() {
        let base = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        var modified = base
        modified.removableMedia = [RemovableMediaItem(path: "/tmp/install.iso", readOnly: true)]
        #expect(VMConfiguration.liveEditableFieldsChanged(old: base, new: modified))
        #expect(VMConfiguration.liveEditableFieldsChanged(old: modified, new: base))
    }

    @Test("liveEditableFieldsChanged detects readOnly flip on a removable media item")
    func liveEditableDetectsRemovableMediaReadOnlyFlip() {
        let id = UUID()
        var base = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        base.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        var modified = base
        modified.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: false)]
        #expect(VMConfiguration.liveEditableFieldsChanged(old: base, new: modified))
    }

    @Test("liveEditableFieldsChanged ignores storageDisks changes")
    func liveEditableIgnoresStorageDisksChanges() {
        // Storage disks are restart-only on VZ (storageDevices is fixed at
        // VM start). The live reconcile flow only acts on removableMedia.
        let base = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        var modified = base
        modified.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio)
        ]
        #expect(!VMConfiguration.liveEditableFieldsChanged(old: base, new: modified))
    }

    @Test("liveEditableFieldsChanged still covers existing hotToggleFields")
    func liveEditableCoversHotToggleFields() {
        var base = VMConfiguration(name: "VM", guestOS: .macOS, bootMode: .macOS)
        base.clipboardSharingEnabled = false
        var modified = base
        modified.clipboardSharingEnabled = true
        #expect(VMConfiguration.liveEditableFieldsChanged(old: base, new: modified))
    }

    @Test("liveEditableFieldsChanged returns false for identical configs")
    func liveEditableReturnsFalseForIdenticalConfigs() {
        let base = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        #expect(!VMConfiguration.liveEditableFieldsChanged(old: base, new: base))
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
}
