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
struct VMConfiguration: Codable, Sendable, Equatable {
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

    // MARK: - Serial Console

    /// When `true`, the running VM exposes its serial port over a host-side
    /// AF_UNIX socket so an external terminal (e.g. `socat`/`nc -U`) can attach.
    ///
    /// Host-only and hot-toggleable — see `VMInstance.applyLiveSerialRelayPolicy`.
    var serialSocketRelayEnabled: Bool

    // MARK: - Audio

    /// When `true`, the host microphone is passed through to the guest as a
    /// virtio sound input stream.
    ///
    /// Defaults to `false` so guests cannot silently
    /// listen to the host. Speaker output is always enabled regardless of this flag.
    var microphoneEnabled: Bool

    // MARK: - Guest Agent

    /// When `true`, the macOS guest agent forwards `os.Logger` records to the
    /// host over vsock so they appear in Console.app under
    /// `com.kernova.guest`.
    ///
    /// Defaults to `false` for new and existing VMs:
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

    /// When `true`, the user has explicitly dismissed the sidebar "install
    /// guest agent" nudge for this VM.
    ///
    /// Suppresses only the gentle `.waiting`
    /// affordance — the `.outdated`, `.unresponsive`, and `.expectedMissing`
    /// states still surface because they imply something more urgent than
    /// "you could install this." Defaults to `false` for new and migrated
    /// configs.
    var agentInstallNudgeDismissed: Bool

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

    // MARK: - Storage Disks

    /// Ordered list of disks attached on `vzConfig.storageDevices`.
    ///
    /// Position [0] boots first on EFI guests. The list includes the
    /// bundle's primary disk (`Disk.asif`) and any user-added internal
    /// disks or installer images. `nil` means "use defaults" — the
    /// builder synthesizes a single main-disk entry on first load.
    var storageDisks: [StorageDisk]?

    // MARK: - Removable Media

    /// Hot-pluggable USB mass storage devices on the XHCI controller.
    ///
    /// Each item's `id` is used as the `VZUSBMassStorageDeviceConfiguration.uuid`
    /// so save-state restore can match the configured item against the
    /// saved-state device list. Mutations while the VM is running trigger
    /// a live attach/detach reconcile in `VMLibraryViewModel`.
    var removableMedia: [RemovableMediaItem]?

    // MARK: - Shared Directories

    var sharedDirectories: [SharedDirectory]?

    // MARK: - Install Intent

    /// Pending macOS install plan from the creation wizard.
    ///
    /// Non-nil ⇔ this VM has never completed its initial boot. Cleared exactly
    /// once, after `MacOSInstallService.install(...)` returns successfully. The
    /// presence of this field is what drives `start(_:)` to route through the
    /// install pipeline (and the `.initialBoot` status assignment in reconcile).
    /// Always `nil` for Linux guests.
    var installContext: MacOSInstallContext?

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
        serialSocketRelayEnabled: Bool = false,
        microphoneEnabled: Bool = false,
        agentLogForwardingEnabled: Bool = false,
        lastSeenAgentVersion: String? = nil,
        agentInstallNudgeDismissed: Bool = false,
        hardwareModelData: Data? = nil,
        machineIdentifierData: Data? = nil,
        genericMachineIdentifierData: Data? = nil,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        kernelCommandLine: String? = nil,
        storageDisks: [StorageDisk]? = nil,
        removableMedia: [RemovableMediaItem]? = nil,
        sharedDirectories: [SharedDirectory]? = nil,
        installContext: MacOSInstallContext? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.guestOS = guestOS
        self.bootMode = bootMode
        self.cpuCount = cpuCount ?? guestOS.defaultCPUCount
        self.memorySizeInGB = memorySizeInGB ?? guestOS.defaultMemoryInGB
        self.diskSizeInGB = diskSizeInGB ?? VMGuestOS.defaultDiskSizeInGB
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.displayPPI = displayPPI
        self.displayPreference = displayPreference
        self.lastFullscreenDisplayID = lastFullscreenDisplayID
        self.networkEnabled = networkEnabled
        self.macAddress = macAddress
        self.clipboardSharingEnabled = clipboardSharingEnabled
        self.serialSocketRelayEnabled = serialSocketRelayEnabled
        self.microphoneEnabled = microphoneEnabled
        self.agentLogForwardingEnabled = agentLogForwardingEnabled
        self.lastSeenAgentVersion = lastSeenAgentVersion
        self.agentInstallNudgeDismissed = agentInstallNudgeDismissed
        self.hardwareModelData = hardwareModelData
        self.machineIdentifierData = machineIdentifierData
        self.genericMachineIdentifierData = genericMachineIdentifierData
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.kernelCommandLine = kernelCommandLine
        self.storageDisks = storageDisks
        self.removableMedia = removableMedia
        self.sharedDirectories = sharedDirectories
        self.installContext = installContext
        self.createdAt = createdAt
    }

    // MARK: - Codable

    // RATIONALE: Custom `init(from:)` so newly added optional fields decode
    // as `nil` / their natural default when absent in older configs, rather
    // than failing the whole decode. Every new property must be added here
    // as well — synthesized `Codable` would not surface the choice.
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
        self.serialSocketRelayEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .serialSocketRelayEnabled) ?? false
        self.microphoneEnabled = try c.decode(Bool.self, forKey: .microphoneEnabled)
        self.agentLogForwardingEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentLogForwardingEnabled) ?? false
        self.lastSeenAgentVersion = try c.decodeIfPresent(String.self, forKey: .lastSeenAgentVersion)
        self.agentInstallNudgeDismissed = try c.decodeIfPresent(Bool.self, forKey: .agentInstallNudgeDismissed) ?? false
        self.hardwareModelData = try c.decodeIfPresent(Data.self, forKey: .hardwareModelData)
        self.machineIdentifierData = try c.decodeIfPresent(Data.self, forKey: .machineIdentifierData)
        self.genericMachineIdentifierData = try c.decodeIfPresent(Data.self, forKey: .genericMachineIdentifierData)
        self.kernelPath = try c.decodeIfPresent(String.self, forKey: .kernelPath)
        self.initrdPath = try c.decodeIfPresent(String.self, forKey: .initrdPath)
        self.kernelCommandLine = try c.decodeIfPresent(String.self, forKey: .kernelCommandLine)
        self.storageDisks = try c.decodeIfPresent([StorageDisk].self, forKey: .storageDisks)
        self.removableMedia = try c.decodeIfPresent([RemovableMediaItem].self, forKey: .removableMedia)
        self.sharedDirectories = try c.decodeIfPresent([SharedDirectory].self, forKey: .sharedDirectories)
        self.installContext = try c.decodeIfPresent(MacOSInstallContext.self, forKey: .installContext)
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

        // Regenerate storage disk IDs so virtio block device identifiers
        // and USB UUIDs don't collide with the source bundle. Internal
        // disk paths are updated by the caller after copying files.
        clone.storageDisks = storageDisks?.map { disk in
            StorageDisk(
                id: UUID(),
                path: disk.path,
                readOnly: disk.readOnly,
                label: disk.label,
                isInternal: disk.isInternal,
                kind: disk.kind
            )
        }

        // Regenerate removable media UUIDs for the same reason — VZ save-state
        // matches by device UUID, and two bundles must not claim the same one.
        clone.removableMedia = removableMedia?.map { item in
            RemovableMediaItem(
                id: UUID(),
                path: item.path,
                readOnly: item.readOnly,
                label: item.label
            )
        }

        // Regenerate shared directory IDs to avoid VirtioFS collisions
        clone.sharedDirectories = sharedDirectories?.map { dir in
            SharedDirectory(id: UUID(), path: dir.path, readOnly: dir.readOnly)
        }

        // Clones copy the source bundle's post-install artifacts (HardwareModel,
        // MachineIdentifier, Disk.asif contents) so they're already installed.
        // Preserving installContext would falsely mark the clone as awaiting
        // an initial boot.
        clone.installContext = nil

        return clone
    }

    /// Generates a unique clone name by appending " Copy", " Copy 2", etc.
    static func generateCloneName(baseName: String, existingNames: [String]) -> String {
        UniqueName.firstAvailable(prefix: "\(baseName) Copy", existing: existingNames)
    }

    // MARK: - Computed

    var memorySizeInBytes: UInt64 {
        UInt64(memorySizeInGB) * 1024 * 1024 * 1024
    }

    // MARK: - Hot-Toggleable Fields

    /// Fields the user may edit while the VM is running.
    ///
    /// Changes to these
    /// bypass the `VMSettingsView` read-only settings lock so the user can
    /// flip them mid-session.
    ///
    /// Most also affect runtime guest behavior and are pushed to the live
    /// guest agent via `PolicyUpdate` on the vsock control channel — but the
    /// `applyLivePolicy` handler checks each such field directly rather than
    /// iterating this list, so a host-only UI preference like
    /// `agentInstallNudgeDismissed` (which suppresses a sidebar nudge but
    /// has no guest-side effect) is safe to include.
    static let hotToggleFields: [KeyPath<VMConfiguration, Bool> & Sendable] = [
        \.agentLogForwardingEnabled,
        \.clipboardSharingEnabled,
        \.serialSocketRelayEnabled,
        \.agentInstallNudgeDismissed,
    ]

    /// Returns `true` if any field that is editable while the VM is running
    /// differs between `old` and `new`.
    ///
    /// Combines the `Bool`-typed `hotToggleFields` with the removable
    /// media list (which is not `Bool` and therefore can't fit in the
    /// typed key-path array).
    static func liveEditableFieldsChanged(
        old: VMConfiguration,
        new: VMConfiguration
    ) -> Bool {
        if hotToggleFields.contains(where: { old[keyPath: $0] != new[keyPath: $0] }) {
            return true
        }
        return removableMediaChanged(old: old, new: new)
    }

    /// Returns `true` if the removable media list differs between `old`
    /// and `new`.
    ///
    /// Compares the lists by value; the reconcile flow does the per-item
    /// diff to determine which entries need attach / detach / reattach.
    static func removableMediaChanged(old: VMConfiguration, new: VMConfiguration) -> Bool {
        (old.removableMedia ?? []) != (new.removableMedia ?? [])
    }
}

// MARK: - SharedDirectory

/// A host directory shared with the guest VM via VirtioFS.
struct SharedDirectory: Codable, Sendable, Equatable {
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
