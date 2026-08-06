import Foundation

/// The user's preferred display hosting for a VM on start/resume.
enum VMDisplayPreference: String, Codable, Sendable, Equatable {
    case inline
    case popOut
    case fullscreen
}

/// Persistent configuration for a virtual machine, serialized to `config.json`
/// inside each VM bundle directory.
///
/// > Important: **Any new property must be added to the custom `init(from:)`
/// > as well.**
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

    /// When `true`, a cold boot rewrites `displayWidth`/`displayHeight`/`displayPPI`
    /// to fit the window or screen the display is about to appear in.
    ///
    /// Ignored when a save file exists — VZ restore requires the saved
    /// configuration.
    var displaySizesToWindow: Bool

    /// The user's intent for guest display density: `true` boots Retina-sharp
    /// (double the pixels at `DisplayBootSizing.hiDPIPixelsPerInch`), `false` at 1×.
    ///
    /// `displayWidth`/`displayHeight`/`displayPPI` stay the values VZ receives;
    /// with `displaySizesToWindow` on they are the previous boot's computed
    /// artifact and only this flag survives to the next one. Linux guests ignore
    /// it — a virtio scanout carries no density.
    var displayHiDPI: Bool

    /// Backs `VZVirtualMachineView.automaticallyReconfiguresDisplay`, letting the
    /// guest reconfigure its display to follow the window as it is resized.
    ///
    /// A macOS guest honors it from macOS 14 on; earlier ones scale instead.
    var displayAutoResizes: Bool

    var displayPreference: VMDisplayPreference
    var lastFullscreenDisplayID: UInt32?

    // MARK: - Network

    var networkEnabled: Bool
    var macAddress: String?

    // MARK: - Clipboard Sharing

    /// When `true`, a SPICE agent console port is configured to enable clipboard
    /// exchange between host and guest via the clipboard panel window.
    var clipboardSharingEnabled: Bool

    /// When `true`, the host clipboard is polled and forwarded to the guest
    /// automatically, and inbound guest clipboard content is written straight to
    /// the host clipboard — removing the clipboard window's manual gate in both
    /// directions.
    ///
    /// Gated on `clipboardSharingEnabled`; because the guest gains continuous
    /// read of whatever is copied on the host, enabling it requires explicit
    /// confirmation. Off by default.
    var clipboardPassthroughEnabled: Bool

    // MARK: - Serial Console

    /// When `true`, the running VM exposes its serial port over a host-side
    /// AF_UNIX socket so an external terminal (e.g. `socat`/`nc -U`) can attach.
    var serialSocketRelayEnabled: Bool

    // MARK: - Audio

    /// When `true`, the host's audio input is passed through to the guest as a
    /// virtio sound input stream.
    ///
    /// Defaults to `false` so guests cannot silently listen to the host.
    var audioInputEnabled: Bool

    /// When `true`, guest audio is routed to the host's audio output as a virtio
    /// sound output stream.
    ///
    /// When both this and `audioInputEnabled` are `false`, no virtio sound
    /// device is configured at all.
    var audioOutputEnabled: Bool

    // MARK: - Guest Agent

    /// When `true`, the macOS guest agent forwards `os.Logger` records to the
    /// host over vsock so they appear in Console.app under `app.kernova.guest`.
    ///
    /// Opt-in. Linux guests have no Kernova agent and ignore this flag.
    var agentLogForwardingEnabled: Bool

    /// The most recent guest-reported agent version observed on this VM's
    /// control channel (`Hello.agent_info.agent_version`), or `nil` until the
    /// host has seen at least one successful Hello.
    ///
    /// Persisted, never reset on stop: it suppresses the sidebar install nudge
    /// for stopped VMs and arms the post-start watchdog.
    var lastSeenAgentVersion: String?

    /// The most recent guest-reported OS version observed on this VM's control
    /// channel (`Hello.agent_info.os_version`), or `nil` when no agent has
    /// vouched for one — a fresh VM, an agent that reported no version, or the
    /// post-start watchdog concluding a previously-seen agent is gone.
    var lastSeenGuestOSVersion: String?

    /// When `true`, the user has explicitly dismissed the sidebar "install
    /// guest agent" nudge for this VM.
    ///
    /// Suppresses only the gentle `.waiting` affordance — `.outdated`,
    /// `.unresponsive`, and `.expectedMissing` still surface.
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

    /// App-scoped security bookmarks for `kernelPath` / `initrdPath`
    /// (user-picked files re-read on every boot); see
    /// ``StorageDisk/bookmark`` for the nil semantics.
    var kernelBookmark: Data?
    var initrdBookmark: Data?

    // MARK: - Storage Disks

    /// Ordered list of disks attached on `vzConfig.storageDevices`; position [0]
    /// boots first on EFI guests.
    ///
    /// `nil` means "use defaults" — the builder synthesizes a single main-disk
    /// entry on first load.
    var storageDisks: [StorageDisk]?

    // MARK: - Removable Media

    /// Hot-pluggable USB mass storage devices on the XHCI controller.
    ///
    /// Each item's `id` is used as the `VZUSBMassStorageDeviceConfiguration.uuid`
    /// so save-state restore can match the configured item against the
    /// saved-state device list.
    var removableMedia: [RemovableMediaItem]?

    // MARK: - Shared Directories

    var sharedDirectories: [SharedDirectory]?

    // MARK: - Install Intent

    /// Pending macOS install plan from the creation wizard.
    ///
    /// Non-nil ⇔ this VM has never completed its initial boot: its presence
    /// routes `start(_:)` through the install pipeline. Cleared exactly once,
    /// after a successful install. Always `nil` for Linux guests.
    var installContext: MacOSInstallContext?

    /// Pending Linux installer-image download from the creation wizard.
    ///
    /// Non-nil ⇔ this VM has never completed its initial boot: its presence
    /// routes `start(_:)` through the download pipeline. Cleared exactly once,
    /// after the verified ISO is attached. Always `nil` for macOS guests, and
    /// for a Linux guest whose ISO the user picked off their own disk.
    var linuxInstallContext: LinuxImageDownloadContext?

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
        displaySizesToWindow: Bool = true,
        displayHiDPI: Bool = true,
        displayAutoResizes: Bool = true,
        displayPreference: VMDisplayPreference = .inline,
        lastFullscreenDisplayID: UInt32? = nil,
        networkEnabled: Bool = true,
        macAddress: String? = nil,
        clipboardSharingEnabled: Bool = false,
        clipboardPassthroughEnabled: Bool = false,
        serialSocketRelayEnabled: Bool = false,
        audioInputEnabled: Bool = false,
        audioOutputEnabled: Bool = true,
        agentLogForwardingEnabled: Bool = false,
        lastSeenAgentVersion: String? = nil,
        lastSeenGuestOSVersion: String? = nil,
        agentInstallNudgeDismissed: Bool = false,
        hardwareModelData: Data? = nil,
        machineIdentifierData: Data? = nil,
        genericMachineIdentifierData: Data? = nil,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        kernelCommandLine: String? = nil,
        kernelBookmark: Data? = nil,
        initrdBookmark: Data? = nil,
        storageDisks: [StorageDisk]? = nil,
        removableMedia: [RemovableMediaItem]? = nil,
        sharedDirectories: [SharedDirectory]? = nil,
        installContext: MacOSInstallContext? = nil,
        linuxInstallContext: LinuxImageDownloadContext? = nil,
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
        self.displaySizesToWindow = displaySizesToWindow
        self.displayHiDPI = displayHiDPI
        self.displayAutoResizes = displayAutoResizes
        self.displayPreference = displayPreference
        self.lastFullscreenDisplayID = lastFullscreenDisplayID
        self.networkEnabled = networkEnabled
        self.macAddress = macAddress
        self.clipboardSharingEnabled = clipboardSharingEnabled
        self.clipboardPassthroughEnabled = clipboardPassthroughEnabled
        self.serialSocketRelayEnabled = serialSocketRelayEnabled
        self.audioInputEnabled = audioInputEnabled
        self.audioOutputEnabled = audioOutputEnabled
        self.agentLogForwardingEnabled = agentLogForwardingEnabled
        self.lastSeenAgentVersion = lastSeenAgentVersion
        self.lastSeenGuestOSVersion = lastSeenGuestOSVersion
        self.agentInstallNudgeDismissed = agentInstallNudgeDismissed
        self.hardwareModelData = hardwareModelData
        self.machineIdentifierData = machineIdentifierData
        self.genericMachineIdentifierData = genericMachineIdentifierData
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.kernelCommandLine = kernelCommandLine
        self.kernelBookmark = kernelBookmark
        self.initrdBookmark = initrdBookmark
        self.storageDisks = storageDisks
        self.removableMedia = removableMedia
        self.sharedDirectories = sharedDirectories
        self.installContext = installContext
        self.linuxInstallContext = linuxInstallContext
        self.createdAt = createdAt
    }

    // MARK: - Codable

    // Custom `init(from:)` for the non-optional fields with defaults
    // (`clipboardPassthroughEnabled ?? false`, `audioOutputEnabled ?? true`, …):
    // synthesized `Codable` would `decode` them and fail the whole decode when
    // the key is absent from a config. (Optionals are not the reason —
    // synthesis already gives those `decodeIfPresent`.)
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
        self.displaySizesToWindow = try c.decodeIfPresent(Bool.self, forKey: .displaySizesToWindow) ?? true
        self.displayHiDPI = try c.decodeIfPresent(Bool.self, forKey: .displayHiDPI) ?? true
        self.displayAutoResizes = try c.decodeIfPresent(Bool.self, forKey: .displayAutoResizes) ?? true
        self.displayPreference = try c.decode(VMDisplayPreference.self, forKey: .displayPreference)
        self.lastFullscreenDisplayID = try c.decodeIfPresent(UInt32.self, forKey: .lastFullscreenDisplayID)
        self.networkEnabled = try c.decode(Bool.self, forKey: .networkEnabled)
        self.macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
        self.clipboardSharingEnabled = try c.decode(Bool.self, forKey: .clipboardSharingEnabled)
        self.clipboardPassthroughEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .clipboardPassthroughEnabled) ?? false
        self.serialSocketRelayEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .serialSocketRelayEnabled) ?? false
        self.audioInputEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioInputEnabled) ?? false
        self.audioOutputEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioOutputEnabled) ?? true
        self.agentLogForwardingEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentLogForwardingEnabled) ?? false
        self.lastSeenAgentVersion = try c.decodeIfPresent(String.self, forKey: .lastSeenAgentVersion)
        self.lastSeenGuestOSVersion = try c.decodeIfPresent(String.self, forKey: .lastSeenGuestOSVersion)
        self.agentInstallNudgeDismissed = try c.decodeIfPresent(Bool.self, forKey: .agentInstallNudgeDismissed) ?? false
        self.hardwareModelData = try c.decodeIfPresent(Data.self, forKey: .hardwareModelData)
        self.machineIdentifierData = try c.decodeIfPresent(Data.self, forKey: .machineIdentifierData)
        self.genericMachineIdentifierData = try c.decodeIfPresent(Data.self, forKey: .genericMachineIdentifierData)
        self.kernelPath = try c.decodeIfPresent(String.self, forKey: .kernelPath)
        self.initrdPath = try c.decodeIfPresent(String.self, forKey: .initrdPath)
        self.kernelCommandLine = try c.decodeIfPresent(String.self, forKey: .kernelCommandLine)
        self.kernelBookmark = try c.decodeIfPresent(Data.self, forKey: .kernelBookmark)
        self.initrdBookmark = try c.decodeIfPresent(Data.self, forKey: .initrdBookmark)
        self.storageDisks = try c.decodeIfPresent([StorageDisk].self, forKey: .storageDisks)
        self.removableMedia = try c.decodeIfPresent([RemovableMediaItem].self, forKey: .removableMedia)
        self.sharedDirectories = try c.decodeIfPresent([SharedDirectory].self, forKey: .sharedDirectories)
        self.installContext = try c.decodeIfPresent(MacOSInstallContext.self, forKey: .installContext)
        self.linuxInstallContext = try c.decodeIfPresent(
            LinuxImageDownloadContext.self, forKey: .linuxInstallContext)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    // MARK: - Persistence Coding

    /// Decoder configured for `config.json` (ISO-8601 dates).
    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encoder configured for `config.json` (ISO-8601 dates, pretty-printed,
    /// stable key order).
    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Reads and decodes `config.json` from a VM bundle directory.
    static func load(fromBundle bundleURL: URL) throws -> VMConfiguration {
        let data = try Data(contentsOf: VMBundleLayout(bundleURL: bundleURL).configURL)
        return try makeJSONDecoder().decode(VMConfiguration.self, from: data)
    }

    // MARK: - Cloning

    /// Returns a new configuration suitable for a cloned VM instance.
    ///
    /// Platform identity fields (`macAddress`, `machineIdentifierData`,
    /// `genericMachineIdentifierData`) are **not** regenerated here — the caller
    /// always replaces `macAddress`, and replaces the machine identifiers or
    /// keeps them per the clone machine-ID preference.
    func clonedForNewInstance(existingNames: [String]) -> VMConfiguration {
        var clone = self
        clone.id = UUID()
        clone.createdAt = Date()
        clone.name = Self.generateCloneName(baseName: name, existingNames: existingNames)
        clone.displayPreference = .inline
        clone.lastFullscreenDisplayID = nil

        // Regenerate IDs so virtio block device identifiers and USB UUIDs don't
        // collide with the source bundle. Bookmarks carry through — the clone
        // references the same external files.
        clone.storageDisks = storageDisks?.map { disk in
            StorageDisk(
                id: UUID(),
                path: disk.path,
                readOnly: disk.readOnly,
                label: disk.label,
                isInternal: disk.isInternal,
                kind: disk.kind,
                bookmark: disk.bookmark
            )
        }

        // Regenerate removable media UUIDs for the same reason — VZ save-state
        // matches by device UUID, and two bundles must not claim the same one.
        clone.removableMedia = removableMedia?.map { item in
            RemovableMediaItem(
                id: UUID(),
                path: item.path,
                readOnly: item.readOnly,
                label: item.label,
                bookmark: item.bookmark
            )
        }

        // Regenerate shared directory IDs to avoid VirtioFS collisions
        clone.sharedDirectories = sharedDirectories?.map { dir in
            SharedDirectory(id: UUID(), path: dir.path, readOnly: dir.readOnly, bookmark: dir.bookmark)
        }

        // The clone copies the source bundle's post-install artifacts, so
        // preserving either install context would falsely mark it as awaiting
        // an initial boot.
        clone.installContext = nil
        clone.linuxInstallContext = nil

        // A clone's guest-agent state hasn't been evaluated by the user, so let
        // the install nudge surface again rather than inheriting the dismissal.
        clone.agentInstallNudgeDismissed = false

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

    /// The stored `displayWidth`/`displayHeight`/`displayPPI` trio as one value.
    var displayResolution: DisplayBootSizing.Resolution {
        get {
            DisplayBootSizing.Resolution(
                width: displayWidth, height: displayHeight, ppi: displayPPI)
        }
        set {
            displayWidth = newValue.width
            displayHeight = newValue.height
            displayPPI = newValue.ppi
        }
    }

    // MARK: - Hot-Toggleable Fields

    /// Fields the user may edit while the VM is running.
    ///
    /// Changes to these bypass the read-only settings lock. Entries need not
    /// have a guest-side effect — `applyLivePolicy` checks the fields it pushes
    /// to the guest directly rather than iterating this list.
    static let hotToggleFields: [KeyPath<VMConfiguration, Bool> & Sendable] = [
        \.agentLogForwardingEnabled,
        \.clipboardSharingEnabled,
        \.clipboardPassthroughEnabled,
        \.serialSocketRelayEnabled,
        \.agentInstallNudgeDismissed,
        \.displayAutoResizes,
    ]

    /// Returns `true` if any field that is editable while the VM is running
    /// differs between `old` and `new`.
    static func liveEditableFieldsChanged(
        old: VMConfiguration,
        new: VMConfiguration
    ) -> Bool {
        if hotToggleFields.contains(where: { old[keyPath: $0] != new[keyPath: $0] }) {
            return true
        }
        return removableMediaChanged(old: old, new: new)
    }

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

    /// App-scoped security bookmark for `path` (a user-picked directory);
    /// see ``StorageDisk/bookmark`` for the nil semantics.
    var bookmark: Data?

    init(id: UUID = UUID(), path: String, readOnly: Bool = false, bookmark: Data? = nil) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
        self.bookmark = bookmark
    }

    /// The last path component, used as the display name in the UI and as the share name in VirtioFS.
    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
