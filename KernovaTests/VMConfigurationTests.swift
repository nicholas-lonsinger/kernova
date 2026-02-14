import Testing
import Foundation
@testable import Kernova

@Suite("VMConfiguration Tests")
struct VMConfigurationTests {

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
            diskSizeInGB: 200,
            notes: "Test notes"
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
        #expect(decoded.notes == original.notes)
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

    @Test("Backward compatibility: decoding JSON without genericMachineIdentifierData")
    func backwardCompatibilityGenericMachineIdentifier() throws {
        // Simulate a config.json from before the genericMachineIdentifierData field existed
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "Old VM",
            "guestOS": "linux",
            "bootMode": "efi",
            "cpuCount": 4,
            "memorySizeInGB": 8,
            "diskSizeInGB": 64,
            "displayWidth": 1920,
            "displayHeight": 1200,
            "displayPPI": 144,
            "networkEnabled": true,
            "createdAt": "2025-01-01T00:00:00Z",
            "notes": ""
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(json.utf8))

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

    @Test("Configuration preserves isoPath for EFI boot")
    func isoPathRoundTrip() throws {
        let config = VMConfiguration(
            name: "EFI Linux VM",
            guestOS: .linux,
            bootMode: .efi,
            isoPath: "/Users/test/Downloads/ubuntu.iso"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.isoPath == "/Users/test/Downloads/ubuntu.iso")
    }

    @Test("Backward compatibility: decoding JSON without isoPath field")
    func backwardCompatibilityIsoPath() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "Old EFI VM",
            "guestOS": "linux",
            "bootMode": "efi",
            "cpuCount": 4,
            "memorySizeInGB": 8,
            "diskSizeInGB": 64,
            "displayWidth": 1920,
            "displayHeight": 1200,
            "displayPPI": 144,
            "networkEnabled": true,
            "createdAt": "2025-01-01T00:00:00Z",
            "notes": ""
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(json.utf8))

        #expect(config.name == "Old EFI VM")
        #expect(config.isoPath == nil)
    }

    @Test("Backward compatibility: decoding JSON without sharedDirectories field")
    func backwardCompatibilitySharedDirectories() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "Old VM",
            "guestOS": "linux",
            "bootMode": "efi",
            "cpuCount": 4,
            "memorySizeInGB": 8,
            "diskSizeInGB": 64,
            "displayWidth": 1920,
            "displayHeight": 1200,
            "displayPPI": 144,
            "networkEnabled": true,
            "createdAt": "2025-01-01T00:00:00Z",
            "notes": ""
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(json.utf8))

        #expect(config.sharedDirectories == nil)
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
            isoPath: "/Users/test/Downloads/ubuntu.iso",
            bootFromDiscImage: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfiguration.self, from: data)

        #expect(decoded.bootFromDiscImage == true)
        #expect(decoded.isoPath == "/Users/test/Downloads/ubuntu.iso")
    }

    @Test("Backward compatibility: decoding JSON without bootFromDiscImage defaults to false")
    func backwardCompatibilityBootFromDiscImage() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "Old EFI VM",
            "guestOS": "linux",
            "bootMode": "efi",
            "cpuCount": 4,
            "memorySizeInGB": 8,
            "diskSizeInGB": 64,
            "displayWidth": 1920,
            "displayHeight": 1200,
            "displayPPI": 144,
            "networkEnabled": true,
            "isoPath": "/path/to/old.iso",
            "createdAt": "2025-01-01T00:00:00Z",
            "notes": ""
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(json.utf8))

        #expect(config.name == "Old EFI VM")
        #expect(config.isoPath == "/path/to/old.iso")
        #expect(config.bootFromDiscImage == false)
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

}
