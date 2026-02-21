import Foundation

/// Persistent configuration for a virtual machine.
///
/// This type is serialized to `config.json` inside each VM bundle directory.
struct VMConfiguration: Codable, Identifiable, Sendable, Equatable {

    // MARK: - Identity

    var id: UUID
    var name: String
    var guestOS: VMGuestOS
    var bootMode: VMBootMode

    // MARK: - Resources

    var cpuCount: Int
    var memorySizeInGB: Int
    var diskSizeInGB: Int

    // MARK: - Display

    var displayWidth: Int
    var displayHeight: Int
    var displayPPI: Int
    var prefersFullscreen: Bool

    // MARK: - Network

    var networkEnabled: Bool
    var macAddress: String?

    // MARK: - macOS-specific

    /// Serialized `VZMacHardwareModel.dataRepresentation`.
    var hardwareModelData: Data?

    /// Serialized `VZMacMachineIdentifier.dataRepresentation`.
    var machineIdentifierData: Data?

    // MARK: - EFI / Linux generic platform

    /// Serialized `VZGenericMachineIdentifier.dataRepresentation`.
    var genericMachineIdentifierData: Data?

    // MARK: - Disc Drive

    /// Path to an ISO image attached as a USB mass storage device.
    var isoPath: String?

    /// When `true` and `bootMode == .efi`, the ISO device is placed before the main disk
    /// so the EFI firmware discovers it first.
    var bootFromDiscImage: Bool

    // MARK: - Linux kernel boot

    var kernelPath: String?
    var initrdPath: String?
    var kernelCommandLine: String?

    // MARK: - Shared Directories

    var sharedDirectories: [SharedDirectory]?

    // MARK: - Metadata

    var createdAt: Date
    var notes: String

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        name: String,
        guestOS: VMGuestOS,
        bootMode: VMBootMode,
        cpuCount: Int? = nil,
        memorySizeInGB: Int? = nil,
        diskSizeInGB: Int? = nil,
        displayWidth: Int = 1920,
        displayHeight: Int = 1200,
        displayPPI: Int = 144,
        prefersFullscreen: Bool = false,
        networkEnabled: Bool = true,
        macAddress: String? = nil,
        hardwareModelData: Data? = nil,
        machineIdentifierData: Data? = nil,
        genericMachineIdentifierData: Data? = nil,
        isoPath: String? = nil,
        bootFromDiscImage: Bool = false,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        kernelCommandLine: String? = nil,
        sharedDirectories: [SharedDirectory]? = nil,
        createdAt: Date = Date(),
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.guestOS = guestOS
        self.bootMode = bootMode
        self.cpuCount = cpuCount ?? guestOS.defaultCPUCount
        self.memorySizeInGB = memorySizeInGB ?? guestOS.defaultMemoryInGB
        self.diskSizeInGB = diskSizeInGB ?? guestOS.defaultDiskSizeInGB
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.displayPPI = displayPPI
        self.prefersFullscreen = prefersFullscreen
        self.networkEnabled = networkEnabled
        self.macAddress = macAddress
        self.hardwareModelData = hardwareModelData
        self.machineIdentifierData = machineIdentifierData
        self.genericMachineIdentifierData = genericMachineIdentifierData
        self.isoPath = isoPath
        self.bootFromDiscImage = bootFromDiscImage
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.kernelCommandLine = kernelCommandLine
        self.sharedDirectories = sharedDirectories
        self.createdAt = createdAt
        self.notes = notes
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, guestOS, bootMode
        case cpuCount, memorySizeInGB, diskSizeInGB
        case displayWidth, displayHeight, displayPPI, prefersFullscreen
        case networkEnabled, macAddress
        case hardwareModelData, machineIdentifierData
        case genericMachineIdentifierData
        case isoPath, bootFromDiscImage
        case kernelPath, initrdPath, kernelCommandLine
        case sharedDirectories
        case createdAt, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        guestOS = try container.decode(VMGuestOS.self, forKey: .guestOS)
        bootMode = try container.decode(VMBootMode.self, forKey: .bootMode)
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        memorySizeInGB = try container.decode(Int.self, forKey: .memorySizeInGB)
        diskSizeInGB = try container.decode(Int.self, forKey: .diskSizeInGB)
        displayWidth = try container.decode(Int.self, forKey: .displayWidth)
        displayHeight = try container.decode(Int.self, forKey: .displayHeight)
        displayPPI = try container.decode(Int.self, forKey: .displayPPI)
        prefersFullscreen = try container.decodeIfPresent(Bool.self, forKey: .prefersFullscreen) ?? false
        networkEnabled = try container.decode(Bool.self, forKey: .networkEnabled)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        hardwareModelData = try container.decodeIfPresent(Data.self, forKey: .hardwareModelData)
        machineIdentifierData = try container.decodeIfPresent(Data.self, forKey: .machineIdentifierData)
        genericMachineIdentifierData = try container.decodeIfPresent(Data.self, forKey: .genericMachineIdentifierData)
        isoPath = try container.decodeIfPresent(String.self, forKey: .isoPath)
        bootFromDiscImage = try container.decodeIfPresent(Bool.self, forKey: .bootFromDiscImage) ?? false
        kernelPath = try container.decodeIfPresent(String.self, forKey: .kernelPath)
        initrdPath = try container.decodeIfPresent(String.self, forKey: .initrdPath)
        kernelCommandLine = try container.decodeIfPresent(String.self, forKey: .kernelCommandLine)
        sharedDirectories = try container.decodeIfPresent([SharedDirectory].self, forKey: .sharedDirectories)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        notes = try container.decode(String.self, forKey: .notes)
    }

    // MARK: - Computed

    var memorySizeInBytes: UInt64 {
        UInt64(memorySizeInGB) * 1024 * 1024 * 1024
    }
}

// MARK: - SharedDirectory

/// A host directory shared with the guest VM via VirtioFS.
struct SharedDirectory: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var path: String
    var readOnly: Bool

    init(id: UUID = UUID(), path: String, readOnly: Bool = false) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
    }

    /// The last path component, used as the display name in the UI and as the share name in VirtioFS.
    var displayName: String {
        (path as NSString).lastPathComponent
    }
}
