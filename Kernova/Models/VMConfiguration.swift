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
        networkEnabled: Bool = true,
        macAddress: String? = nil,
        hardwareModelData: Data? = nil,
        machineIdentifierData: Data? = nil,
        genericMachineIdentifierData: Data? = nil,
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
        self.networkEnabled = networkEnabled
        self.macAddress = macAddress
        self.hardwareModelData = hardwareModelData
        self.machineIdentifierData = machineIdentifierData
        self.genericMachineIdentifierData = genericMachineIdentifierData
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.kernelCommandLine = kernelCommandLine
        self.sharedDirectories = sharedDirectories
        self.createdAt = createdAt
        self.notes = notes
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
