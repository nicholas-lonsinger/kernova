import Testing
import Foundation
@testable import Kernova

@Suite("VMConfiguration Tests")
struct VMConfigurationTests {

    /// Builds a complete `VMConfiguration` JSON string with all required fields populated.
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
            "discImageReadOnly": true,
            "bootFromDiscImage": false,
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

    @Test("Configuration preserves discImagePath for EFI boot")
    func discImagePathRoundTrip() throws {
        let config = VMConfiguration(
            name: "EFI Linux VM",
            guestOS: .linux,
            bootMode: .efi,
            discImagePath: "/Users/test/Downloads/ubuntu.iso"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.discImagePath == "/Users/test/Downloads/ubuntu.iso")
    }

    @Test("Missing optional discImagePath decodes as nil")
    func missingOptionalDiscImagePath() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.discImagePath == nil)
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

    @Test("Configuration preserves bootFromDiscImage flag")
    func bootFromDiscImageRoundTrip() throws {
        let config = VMConfiguration(
            name: "EFI Boot VM",
            guestOS: .linux,
            bootMode: .efi,
            discImagePath: "/Users/test/Downloads/ubuntu.iso",
            bootFromDiscImage: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.bootFromDiscImage == true)
        #expect(decoded.discImagePath == "/Users/test/Downloads/ubuntu.iso")
    }

    @Test("Default bootFromDiscImage is false")
    func defaultBootFromDiscImage() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        #expect(config.bootFromDiscImage == false)
    }

    // MARK: - discImageReadOnly Tests

    @Test("Default discImageReadOnly is true")
    func defaultDiscImageReadOnly() {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        #expect(config.discImageReadOnly == true)
    }

    @Test("discImageReadOnly round-trips false")
    func discImageReadOnlyRoundTrips() throws {
        let config = VMConfiguration(
            name: "Writable Disc VM",
            guestOS: .linux,
            bootMode: .efi,
            discImagePath: "/tmp/data.dmg",
            discImageReadOnly: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.discImageReadOnly == false)
        #expect(decoded.discImagePath == "/tmp/data.dmg")
    }

    // MARK: - AdditionalDisk Tests

    @Test("AdditionalDisk blockDeviceIdentifier fits within 20 characters")
    func additionalDiskBlockDeviceIdentifierLength() {
        let disk = AdditionalDisk(path: "/tmp/data.asif")
        #expect(disk.blockDeviceIdentifier.count <= 20)
        #expect(!disk.blockDeviceIdentifier.isEmpty)
    }

    @Test("AdditionalDisk auto-generates label from filename")
    func additionalDiskAutoLabel() {
        let disk = AdditionalDisk(path: "/Users/test/Downloads/my-data.asif")
        #expect(disk.label == "my-data")
    }

    @Test("AdditionalDisk default readOnly is false")
    func additionalDiskDefaultReadOnly() {
        let disk = AdditionalDisk(path: "/tmp/test.asif")
        #expect(disk.readOnly == false)
    }

    @Test("AdditionalDisk default isInternal is false")
    func additionalDiskDefaultIsInternal() {
        let disk = AdditionalDisk(path: "/tmp/test.asif")
        #expect(disk.isInternal == false)
    }

    @Test("Configuration round-trips additionalDisks")
    func additionalDisksRoundTrip() throws {
        let config = VMConfiguration(
            name: "Multi-Disk VM",
            guestOS: .linux,
            bootMode: .efi,
            additionalDisks: [
                AdditionalDisk(path: "/tmp/data.asif", readOnly: false, label: "Data"),
                AdditionalDisk(path: "/tmp/backup.img", readOnly: true, label: "Backup", isInternal: false),
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.additionalDisks?.count == 2)
        #expect(decoded.additionalDisks?[0].label == "Data")
        #expect(decoded.additionalDisks?[0].readOnly == false)
        #expect(decoded.additionalDisks?[0].isInternal == false)
        #expect(decoded.additionalDisks?[0].id == config.additionalDisks?[0].id)
        #expect(decoded.additionalDisks?[0].blockDeviceIdentifier == config.additionalDisks?[0].blockDeviceIdentifier)
        #expect(decoded.additionalDisks?[1].label == "Backup")
        #expect(decoded.additionalDisks?[1].readOnly == true)
        #expect(decoded.additionalDisks?[1].isInternal == false)
        #expect(decoded.additionalDisks?[1].id == config.additionalDisks?[1].id)
        #expect(decoded.additionalDisks?[1].blockDeviceIdentifier == config.additionalDisks?[1].blockDeviceIdentifier)
    }

    @Test("AdditionalDisk displayName returns last path component")
    func additionalDiskDisplayName() {
        let disk = AdditionalDisk(path: "/Users/test/VMs/data.asif")
        #expect(disk.displayName == "data.asif")
    }

    @Test("Missing optional additionalDisks decodes as nil")
    func missingOptionalAdditionalDisks() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.additionalDisks == nil)
    }

    @Test("Clone regenerates additionalDisk IDs")
    func cloneRegeneratesAdditionalDiskIDs() {
        let originalDisk = AdditionalDisk(path: "/tmp/data.asif", label: "Data")
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi,
            additionalDisks: [originalDisk]
        )

        let clone = config.clonedForNewInstance(existingNames: [])

        #expect(clone.additionalDisks?.count == 1)
        #expect(clone.additionalDisks?[0].id != originalDisk.id)
        #expect(clone.additionalDisks?[0].path == originalDisk.path)
        #expect(clone.additionalDisks?[0].label == originalDisk.label)
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
    /// decodes back, and asserts equality. Tripwire for the custom
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
            discImagePath: "/path/to/disc.iso",
            discImageReadOnly: false,
            bootFromDiscImage: true,
            kernelPath: "/path/to/kernel",
            initrdPath: "/path/to/initrd",
            kernelCommandLine: "console=ttyS0",
            additionalDisks: [
                AdditionalDisk(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    path: "/disk2.img",
                    readOnly: true,
                    label: "data",
                    isInternal: false
                ),
            ],
            sharedDirectories: [
                SharedDirectory(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    path: "/host/shared",
                    readOnly: true
                ),
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
        // microphoneEnabled, discImageReadOnly, bootFromDiscImage
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

}
