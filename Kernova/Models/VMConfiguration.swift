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
///
/// > Important: This struct uses a custom `init(from:)` (see the `Codable`
/// > section) instead of synthesized `Decodable` so newly added optional
/// > defaults can be migrated cleanly. **Any new property must be added to
/// > the custom `init(from:)` as well.** Optional properties decoded via
/// > synthesized `init(from:)` would default to `nil` silently; the manual
/// > initializer makes that decision explicit.
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

    // MARK: - Guest Agent

    /// When `true`, the macOS guest agent forwards `os.Logger` records to the
    /// host over vsock so they appear in Console.app under
    /// `com.kernova.guest`. Defaults to `false` for new and existing VMs:
    /// log forwarding is opt-in. Linux guests have no Kernova agent and ignore
    /// this flag.
    ///
    /// Hot-toggleable while the VM is running — see `VsockControlService`'s
    /// `PolicyUpdate` delivery.
    var agentLogForwardingEnabled: Bool

    /// The most recent guest-reported agent version observed on this VM's
    /// control channel (`Hello.agent_info.agent_version`). `nil` until the
    /// host has seen at least one successful Hello.
    ///
    /// Drives two pieces of UX:
    /// 1. Suppressing the sidebar "install agent" nudge for stopped VMs whose
    ///    agent has previously connected.
    /// 2. Arming the post-start watchdog (`VMInstance.startAgentPostStartWatchdog`)
    ///    so a VM whose agent was previously installed but doesn't reconnect
    ///    after boot surfaces a "didn't reconnect" badge instead of the
    ///    generic install nudge.
    ///
    /// Persisted, never reset on stop. Updated whenever the guest reports a
    /// new version (e.g. user-side update or downgrade inside the VM).
    var lastSeenAgentVersion: String?

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
        agentLogForwardingEnabled: Bool = false,
        lastSeenAgentVersion: String? = nil,
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
        self.agentLogForwardingEnabled = agentLogForwardingEnabled
        self.lastSeenAgentVersion = lastSeenAgentVersion
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

    // MARK: - Codable

    // RATIONALE: Custom `init(from:)` so newly added fields default cleanly
    // when decoding configs that pre-date their introduction
    // (`agentLogForwardingEnabled` defaults to `false`,
    // `lastSeenAgentVersion` defaults to `nil`). Other fields keep their
    // existing required/optional decoding semantics.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.guestOS = try c.decode(VMGuestOS.self, forKey: .guestOS)
        self.bootMode = try c.decode(VMBootMode.self, forKey: .bootMode)
        self.cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        self.memorySizeInGB = try c.decode(Int.self, forKey: .memorySizeInGB)
        self.diskSizeInGB = try c.decode(Int.self, forKey: .diskSizeInGB)
        self.displayWidth = try c.decode(Int.self, forKey: .displayWidth)
        self.displayHeight = try c.decode(Int.self, forKey: .displayHeight)
        self.displayPPI = try c.decode(Int.self, forKey: .displayPPI)
        self.displayPreference = try c.decode(VMDisplayPreference.self, forKey: .displayPreference)
        self.lastFullscreenDisplayID = try c.decodeIfPresent(UInt32.self, forKey: .lastFullscreenDisplayID)
        self.networkEnabled = try c.decode(Bool.self, forKey: .networkEnabled)
        self.macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
        self.clipboardSharingEnabled = try c.decode(Bool.self, forKey: .clipboardSharingEnabled)
        self.microphoneEnabled = try c.decode(Bool.self, forKey: .microphoneEnabled)
        self.agentLogForwardingEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentLogForwardingEnabled) ?? false
        self.lastSeenAgentVersion = try c.decodeIfPresent(String.self, forKey: .lastSeenAgentVersion)
        self.hardwareModelData = try c.decodeIfPresent(Data.self, forKey: .hardwareModelData)
        self.machineIdentifierData = try c.decodeIfPresent(Data.self, forKey: .machineIdentifierData)
        self.genericMachineIdentifierData = try c.decodeIfPresent(Data.self, forKey: .genericMachineIdentifierData)
        self.discImagePath = try c.decodeIfPresent(String.self, forKey: .discImagePath)
        self.discImageReadOnly = try c.decode(Bool.self, forKey: .discImageReadOnly)
        self.bootFromDiscImage = try c.decode(Bool.self, forKey: .bootFromDiscImage)
        self.kernelPath = try c.decodeIfPresent(String.self, forKey: .kernelPath)
        self.initrdPath = try c.decodeIfPresent(String.self, forKey: .initrdPath)
        self.kernelCommandLine = try c.decodeIfPresent(String.self, forKey: .kernelCommandLine)
        self.additionalDisks = try c.decodeIfPresent([AdditionalDisk].self, forKey: .additionalDisks)
        self.sharedDirectories = try c.decodeIfPresent([SharedDirectory].self, forKey: .sharedDirectories)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
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

    // MARK: - Hot-Toggleable Fields

    /// Fields the user may edit while the VM is running. Changes to these
    /// bypass the read-only settings lock and are pushed to the live guest
    /// agent via `PolicyUpdate` on the vsock control channel.
    ///
    /// Single source of truth — `VMSettingsView` uses this for change
    /// detection, and the live-policy handler that applies these changes to
    /// a running VM consumes the same list.
    static let hotToggleFields: [KeyPath<VMConfiguration, Bool> & Sendable] = [
        \.agentLogForwardingEnabled,
        \.clipboardSharingEnabled,
    ]
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
