import Foundation

/// The user's preferred display hosting for a VM on start/resume.
enum VMDisplayPreference: String, Codable, Sendable, Equatable {
    case inline
    case popOut
    case fullscreen
}

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
    var displayPreference: VMDisplayPreference
    var lastFullscreenDisplayID: UInt32?

    // MARK: - Network

    var networkEnabled: Bool
    var macAddress: String?

    // MARK: - Clipboard Sharing

    /// When `true`, a SPICE agent console port is configured to enable clipboard
    /// exchange between host and guest via the clipboard panel window.
    var clipboardSharingEnabled: Bool

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
        displayPreference: VMDisplayPreference = .inline,
        lastFullscreenDisplayID: UInt32? = nil,
        networkEnabled: Bool = true,
        macAddress: String? = nil,
        clipboardSharingEnabled: Bool = false,
        hardwareModelData: Data? = nil,
        machineIdentifierData: Data? = nil,
        genericMachineIdentifierData: Data? = nil,
        isoPath: String? = nil,
        bootFromDiscImage: Bool = false,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        kernelCommandLine: String? = nil,
        sharedDirectories: [SharedDirectory]? = nil,
        createdAt: Date = Date()
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
        self.displayPreference = displayPreference
        self.lastFullscreenDisplayID = lastFullscreenDisplayID
        self.networkEnabled = networkEnabled
        self.macAddress = macAddress
        self.clipboardSharingEnabled = clipboardSharingEnabled
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
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, guestOS, bootMode
        case cpuCount, memorySizeInGB, diskSizeInGB
        case displayWidth, displayHeight, displayPPI, displayPreference, lastFullscreenDisplayID
        case networkEnabled, macAddress
        case clipboardSharingEnabled
        case hardwareModelData, machineIdentifierData
        case genericMachineIdentifierData
        case isoPath, bootFromDiscImage
        case kernelPath, initrdPath, kernelCommandLine
        case sharedDirectories
        case createdAt
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
        displayPreference = try container.decodeIfPresent(VMDisplayPreference.self, forKey: .displayPreference) ?? .inline
        lastFullscreenDisplayID = try container.decodeIfPresent(UInt32.self, forKey: .lastFullscreenDisplayID)
        networkEnabled = try container.decode(Bool.self, forKey: .networkEnabled)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        clipboardSharingEnabled = try container.decodeIfPresent(Bool.self, forKey: .clipboardSharingEnabled) ?? false
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
    }

    // MARK: - Cloning

    /// Returns a new configuration suitable for a cloned VM instance.
    ///
    /// Identity fields (`id`, `createdAt`) are regenerated. The name is derived
    /// from the original via ``generateCloneName(baseName:existingNames:)`` to
    /// avoid collisions. Platform identity fields (`macAddress`,
    /// `machineIdentifierData`, `genericMachineIdentifierData`) are **not**
    /// regenerated here — the caller must replace them with fresh VZ framework
    /// values after cloning.
    func clonedForNewInstance(existingNames: [String]) -> VMConfiguration {
        var clone = self
        clone.id = UUID()
        clone.createdAt = Date()
        clone.name = Self.generateCloneName(baseName: name, existingNames: existingNames)
        clone.displayPreference = .inline
        clone.lastFullscreenDisplayID = nil

        // Regenerate shared directory IDs to avoid VirtioFS collisions
        clone.sharedDirectories = sharedDirectories?.map { dir in
            SharedDirectory(id: UUID(), path: dir.path, readOnly: dir.readOnly)
        }

        return clone
    }

    /// Generates a unique clone name by appending " Copy", " Copy 2", etc.
    static func generateCloneName(baseName: String, existingNames: [String]) -> String {
        let candidate = "\(baseName) Copy"
        if !existingNames.contains(candidate) {
            return candidate
        }
        var counter = 2
        while existingNames.contains("\(baseName) Copy \(counter)") {
            counter += 1
        }
        return "\(baseName) Copy \(counter)"
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
        URL(fileURLWithPath: path).lastPathComponent
    }
}
