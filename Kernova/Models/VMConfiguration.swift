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

    // MARK: - Audio

    /// When `true`, the host microphone is passed through to the guest as a
    /// virtio sound input stream. Defaults to `false` so guests cannot silently
    /// listen to the host. Speaker output is always enabled regardless of this flag.
    var microphoneEnabled: Bool

    // MARK: - macOS-specific

    /// Serialized `VZMacHardwareModel.dataRepresentation`.
    var hardwareModelData: Data?

    /// Serialized `VZMacMachineIdentifier.dataRepresentation`.
    var machineIdentifierData: Data?

    // MARK: - EFI / Linux generic platform

    /// Serialized `VZGenericMachineIdentifier.dataRepresentation`.
    var genericMachineIdentifierData: Data?

    // MARK: - Removable Media

    /// Path to a disk image attached as a USB mass storage device at VM start time.
    /// For runtime hot-plug, see `USBDeviceService`.
    var discImagePath: String?

    /// When `true`, the disc image attachment is read-only. Defaults to `true`.
    var discImageReadOnly: Bool

    /// When `true` and `bootMode == .efi`, the disc image device is placed before the main disk
    /// so the EFI firmware discovers it first.
    var bootFromDiscImage: Bool

    // MARK: - Linux kernel boot

    var kernelPath: String?
    var initrdPath: String?
    var kernelCommandLine: String?

    // MARK: - Storage Disks

    /// Extra disk images attached as virtio block devices (e.g., /dev/vdb on Linux).
    var additionalDisks: [AdditionalDisk]?

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
        microphoneEnabled: Bool = false,
        hardwareModelData: Data? = nil,
        machineIdentifierData: Data? = nil,
        genericMachineIdentifierData: Data? = nil,
        discImagePath: String? = nil,
        discImageReadOnly: Bool = true,
        bootFromDiscImage: Bool = false,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        kernelCommandLine: String? = nil,
        additionalDisks: [AdditionalDisk]? = nil,
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
        self.microphoneEnabled = microphoneEnabled
        self.hardwareModelData = hardwareModelData
        self.machineIdentifierData = machineIdentifierData
        self.genericMachineIdentifierData = genericMachineIdentifierData
        self.discImagePath = discImagePath
        self.discImageReadOnly = discImageReadOnly
        self.bootFromDiscImage = bootFromDiscImage
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.kernelCommandLine = kernelCommandLine
        self.additionalDisks = additionalDisks
        self.sharedDirectories = sharedDirectories
        self.createdAt = createdAt
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

        // Regenerate additional disk IDs to avoid blockDeviceIdentifier collisions.
        // Internal disk paths are updated by the caller after copying files.
        clone.additionalDisks = additionalDisks?.map { disk in
            AdditionalDisk(id: UUID(), path: disk.path, readOnly: disk.readOnly, label: disk.label, isInternal: disk.isInternal)
        }

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

// MARK: - AdditionalDisk

/// A disk image attached as an additional virtio block device.
struct AdditionalDisk: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var path: String
    var readOnly: Bool
    var label: String
    var isInternal: Bool

    init(id: UUID = UUID(), path: String, readOnly: Bool = false, label: String? = nil, isInternal: Bool = false) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
        self.label = label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.isInternal = isInternal
    }

    /// The last path component, used as the display name in the UI.
    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Block device identifier for the guest (up to 20 ASCII chars).
    ///
    /// Derived from the UUID prefix for uniqueness and stability.
    /// Visible in Linux guests at `/dev/disk/by-id/virtio-<identifier>`.
    var blockDeviceIdentifier: String {
        String(id.uuidString.prefix(20))
    }
}
