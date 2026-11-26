import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMConfiguration Tests", .caseScoped)
struct VMConfigurationTests {
    /// Builds a complete `VMConfiguration` JSON string with all required fields populated.
    ///
    /// Pass extra comma-separated JSON fields via `extraFields` to add or override entries,
    /// the recorded `deviceShape` object as `deviceShape` (`nil` records none), and the
    /// guest's `guestOS` and `bootMode`.
    private static func makeBaseJSON(
        name: String = "Base VM",
        guestOS: String = "linux",
        bootMode: String = "efi",
        deviceShape: String? = #"{"virtioSocketDevice": true}"#,
        extraFields: String = ""
    ) -> String {
        let shape = deviceShape.map { "\n                \"deviceShape\": \($0)," } ?? ""
        let extra = extraFields.isEmpty ? "" : ",\n            \(extraFields)"
        return """
            {
                "id": "12345678-1234-1234-1234-123456789012",
                "name": "\(name)",
                "guestOS": "\(guestOS)",
                "bootMode": "\(bootMode)",
                "cpuCount": 4,
                "memorySizeInGB": 8,
                "diskSizeInGB": 64,
                "displayWidth": 1920,
                "displayHeight": 1200,
                "displayPPI": 144,
                "networkEnabled": true,
                "clipboardSharingEnabled": false,\(shape)
                "createdAt": "2025-01-01T00:00:00Z"\(extra)
            }
            """
    }

    @Test("A config written before the drag-and-drop toggle decodes with it on")
    func missingDropFilesFlagDecodesEnabled() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(Self.makeBaseJSON().utf8))

        #expect(config.dropFilesEnabled)
        #expect(
            VMConfiguration(
                name: "New VM", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
                memorySizeInGB: VMGuestOS.macOS.hostMemorySize
            ).dropFilesEnabled)
    }

    // MARK: - SharedDirectory Tests

    @Test("A share written before its mount name was stored decodes mounted by its folder's name")
    func missingMountNameDecodesAsTheFolderName() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","path":"/Users/test/src","readOnly":false}"#
        let decoded = try JSONDecoder().decode(SharedDirectory.self, from: Data(json.utf8))

        #expect(decoded.name == "src")
        #expect(decoded.name == SharedDirectory(path: "/Users/test/src").name)
        let renamed = SharedDirectory(path: "/Users/test/src", name: "abcd-src")
        let roundTripped = try JSONDecoder().decode(
            SharedDirectory.self, from: JSONEncoder().encode(renamed))
        #expect(roundTripped.name == "abcd-src")
    }

    @Test("A removableMedia entry missing notes decodes it as empty, without failing the config decode")
    func missingRemovableMediaNotesDecodesEmpty() throws {
        let json = Self.makeBaseJSON(
            extraFields: """
                "removableMedia": [{"id": "32345678-1234-1234-1234-123456789012", "path": "/ext/i.iso", "readOnly": true, "label": "I"}]
                """
        )
        let decoded = try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: Data(json.utf8))

        #expect(decoded.removableMedia?[0].notes == "")
        #expect(decoded.removableMedia?[0].awaitedAgentScopes == [])
    }

    @Test("Security bookmark fields round-trip through JSON")
    func bookmarkFieldsRoundTrip() throws {
        var original = VMConfiguration(
            name: "Bookmarked VM",
            guestOS: .linux,
            bootMode: .linuxKernel,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize,
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

    // MARK: - StorageDisk Tests

    @Test("StorageDisk notes round-trip through JSON")
    func storageDiskNotesRoundTrip() throws {
        let config = VMConfiguration(
            name: "Multi-Disk VM",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize,
            storageDisks: [
                StorageDisk(
                    path: "/tmp/data.asif", readOnly: false, label: "Data", isInternal: false,
                    kind: .virtio, notes: "holds the build cache")
            ]
        )

        let data = try VMConfiguration.makeJSONEncoder().encode(config)
        let decoded = try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)

        #expect(decoded.storageDisks?[0].notes == "holds the build cache")
    }

    @Test("A storageDisks entry missing notes decodes it as empty, without failing the config decode")
    func missingStorageDiskNotesDecodesEmpty() throws {
        let json = Self.makeBaseJSON(
            extraFields: """
                "storageDisks": [{"id": "22345678-1234-1234-1234-123456789012", "path": "/ext/d.img", "readOnly": false, "label": "D", "isInternal": false, "kind": "virtio"}]
                """
        )
        let decoded = try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: Data(json.utf8))

        #expect(decoded.storageDisks?[0].notes == "")
    }

    // MARK: - Pending Guest Account

    @Test("The account password never reaches the serialized configuration")
    func accountPasswordNeverReachesTheWireFormat() throws {
        let password = "kernova-sentinel-account-password"
        let credentials = GuestProvisioningCredentials(
            fullName: "Ada Lovelace", username: "ada", password: password,
            logsInAutomatically: true, enablesRemoteLogin: true)
        // The only shape the boundary offers: four values to the configuration,
        // the password left with the credentials.
        let config = VMConfiguration(
            name: "Unattended VM",
            guestOS: .macOS,
            bootMode: .macOS,
            cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize,
            pendingGuestAccount: GuestAccountIntent(
                fullName: credentials.fullName, username: credentials.username,
                logsInAutomatically: credentials.logsInAutomatically,
                enablesRemoteLogin: credentials.enablesRemoteLogin))

        let data = try VMConfiguration.makeJSONEncoder().encode(config)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(password))

        // On the keys the file carries, because a `nil` Swift value reads the
        // same whether the field was dropped on the way out or never written.
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let intent = try #require(object["pendingGuestAccount"] as? [String: Any])
        #expect(
            Set(intent.keys) == ["fullName", "username", "logsInAutomatically", "enablesRemoteLogin"]
        )
    }

    // MARK: - linuxInstallContext Tests

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

    // MARK: - Network Mode Tests

    @Test("An isolated config round-trips onto a network only it joins")
    func isolationRoundTripsOntoTheVMsOwnNetwork() throws {
        var config = VMConfiguration(
            name: "Isolated", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.networkMembership = .isolated
        let decoded = try VMConfiguration.makeJSONDecoder().decode(
            VMConfiguration.self, from: VMConfiguration.makeJSONEncoder().encode(config))

        #expect(decoded.networkMembership == .isolated)
        #expect(decoded.joinedNetwork == .vmnet(VmnetNetworkID(kind: .nat, scope: .vm(config.id))))
        // Bridged has no app-managed network to be isolated on.
        var bridged = decoded
        bridged.networkMode = .bridged
        #expect(bridged.joinedNetwork == .bridged)
    }

    @Test("A named network's membership persists as its identifier and joins that network in the VM's mode")
    func namedMembershipRoundTripsAsItsIdentifier() throws {
        let lab = UUID()
        var config = VMConfiguration(
            name: "Member", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.networkMembership = .network(lab)
        let data = try VMConfiguration.makeJSONEncoder().encode(config)
        let stored = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(stored["networkMembership"] as? String == lab.uuidString)

        let decoded = try VMConfiguration.makeJSONDecoder().decode(VMConfiguration.self, from: data)
        #expect(decoded.networkMembership == .network(lab))
        #expect(decoded.joinedNetwork == .vmnet(VmnetNetworkID(kind: .nat, scope: .named(lab))))
        #expect(VMNetworkMembership(rawValue: "common") == .common)
        #expect(VMNetworkMembership(rawValue: "isolated") == .isolated)
        #expect(VMNetworkMembership(rawValue: "Lab") == nil)
    }

    // MARK: - Input Device Mode Tests

    @Test("Configuration preserves an explicit input device mode")
    func inputDeviceModeRoundTrip() throws {
        var config = VMConfiguration(
            name: "Test VM", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
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
            cpuCount: 12,
            memorySizeInGB: .gibibytes(24),
            displayWidth: 2560,
            displayHeight: 1440,
            displayPPI: 192,
            displaySizesToWindow: false,
            displayHiDPI: false,
            displayAutoResizes: false,
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

    // MARK: - Device shape

    @Test(
        "A config with no device shape reads as the devices its boot mode always got",
        arguments: [("macOS", "macOS", true), ("linux", "efi", false), ("linux", "linuxKernel", false)]
    )
    func absentDeviceShapeStatesThePriorDevices(guestOS: String, bootMode: String, socket: Bool) throws {
        let config = try VMConfiguration.makeJSONDecoder().decode(
            VMConfiguration.self,
            from: Data(Self.makeBaseJSON(guestOS: guestOS, bootMode: bootMode, deviceShape: nil).utf8))
        #expect(config.deviceShape == VMDeviceShape(virtioSocketDevice: socket))
        #expect(config.deviceShape == .unrecorded(bootMode: config.bootMode))
    }

    // MARK: - Snapshot revert

    @Test("Adopting a snapshot's state takes its hardware and keeps this VM's identity")
    func adoptingSnapshotStateKeepsIdentity() {
        var current = VMConfiguration(
            name: "Renamed since", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        current.memorySizeInGB = .gibibytes(16)
        current.cpuCount = 8
        current.audioInputEnabled = true
        current.hardwareModelData = Data("current-hardware".utf8)
        current.machineIdentifierData = Data("current-machine".utf8)
        current.genericMachineIdentifierData = Data("current-generic".utf8)
        current.createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        var captured = current
        captured.id = UUID()
        captured.name = "Name at capture time"
        captured.memorySizeInGB = .gibibytes(8)
        captured.cpuCount = 4
        captured.audioInputEnabled = false
        captured.hardwareModelData = Data("captured-hardware".utf8)
        captured.machineIdentifierData = Data("captured-machine".utf8)
        captured.genericMachineIdentifierData = Data("captured-generic".utf8)
        captured.createdAt = Date(timeIntervalSince1970: 1_600_000_000)

        let restored = current.adoptingSnapshotState(captured)

        // Device state the saved state was written under comes back.
        #expect(restored.memorySizeInGB == .gibibytes(8))
        #expect(restored.cpuCount == 4)
        #expect(restored.audioInputEnabled == false)
        // Identity does not — a revert must not hand the guest a different machine.
        #expect(restored.id == current.id)
        #expect(restored.name == "Renamed since")
        #expect(restored.createdAt == current.createdAt)
        #expect(restored.hardwareModelData == current.hardwareModelData)
        #expect(restored.machineIdentifierData == current.machineIdentifierData)
        #expect(restored.genericMachineIdentifierData == current.genericMachineIdentifierData)
    }
}
