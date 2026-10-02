import Foundation
import KernovaKit

/// How an enabled network device attaches to the world.
enum VMNetworkMode: String, Codable, Sendable, Equatable, CaseIterable {
    case shared
    case bridged
    case hostOnly

    /// Whether a saved state taken on one network of this mode restores on
    /// another network of the same mode — what lets a VM holding one move
    /// between its mode's common network and a network of its own.
    var savedStateRestoresOnAnotherNetworkOfThisMode: Bool {
        switch self {
        // Measured Shared to Shared, onto a new network on another subnet
        // (docs/research/2026-09-30-separate-vmnet-networks-isolate-their-guests.md);
        // the same note lists a restore onto another Host Only network as not
        // measured, and Bridged has one network per interface, not a network
        // of its own.
        case .shared: true
        case .hostOnly, .bridged: false
        }
    }
}

/// The user's choice of pointing/keyboard device pair for a macOS guest.
enum VMInputDeviceMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Resolve the pair from the guest's effective macOS version.
    case automatic
    /// The Mac trackpad and keyboard, which only macOS 13+ guests recognize.
    case mac
    /// The USB pointer and keyboard, which every guest recognizes — but a
    /// 13+ guest reads the pointer as a mouse and pins its scrollbars visible.
    case usb
}

/// When the VM display sends system hot keys to the guest instead of letting
/// the host act on them.
enum VMSystemKeyForwarding: String, Codable, Sendable, Equatable, CaseIterable {
    /// The host keeps every system hot key.
    case never
    /// The guest takes them only while its display fills a screen of its own.
    case fullscreenOnly
    /// The guest takes them whenever the display has keyboard focus.
    case always
}

/// Which network of its mode a Shared or Host Only VM joins — membership,
/// which is what expresses guest↔guest reach (docs/NETWORKING.md).
enum VMNetworkMembership: String, Codable, Sendable, Equatable, CaseIterable {
    /// The mode's common network, which every VM of the mode on it shares.
    case common
    /// A network of the VM's own, which no other guest joins.
    case isolated
}

/// A network a VM's device can join.
enum VMJoinedNetwork: Hashable, Sendable {
    /// The host's LAN through a bridged interface — any interface, since
    /// Automatic resolves at start and which link two VMs land on is not
    /// knowable in advance.
    case bridged
    /// An app-managed vmnet network.
    case vmnet(VmnetNetworkID)

    /// Whether this is one VM's network of its own.
    var isOwn: Bool {
        guard case .vmnet(let id) = self else { return false }
        return id.owner != nil
    }

    /// What a build that cannot attach this network lacks, as a refusal
    /// names it.
    var entitledCapability: String {
        switch self {
        case .bridged: "bridged networking"
        case .vmnet(let id) where id.owner != nil: "isolating a virtual machine from other virtual machines"
        case .vmnet(let id) where id.kind == .hostOnly: "host-only networking"
        case .vmnet: "Shared Network"
        }
    }
}

/// Persistent configuration for a virtual machine, serialized to `config.json`
/// inside each VM bundle directory — what a snapshot captures and a revert
/// restores. Per-VM state a revert must leave alone is ``VMHostState``.
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
    /// Persisted under this key as a number of gibibytes.
    var memorySizeInGB: VMMemorySize
    var diskSizeInGB: Int

    // MARK: - Display

    var displayWidth: Int
    var displayHeight: Int
    var displayPPI: Int

    /// When `true`, a cold boot rewrites `displayWidth`/`displayHeight`/`displayPPI`
    /// to fit the window or screen the display is about to appear in.
    ///
    /// Ignored when a save file exists.
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

    // MARK: - Network

    /// When `false`, the VM has no network device at all — the "None" mode.
    var networkEnabled: Bool

    /// How an enabled device attaches; ignored while `networkEnabled` is `false`.
    var networkMode: VMNetworkMode

    /// BSD name of the host interface a bridged VM attaches to (e.g. `en0`), or
    /// `nil` for Automatic — resolved against the host's default route at start.
    var bridgedInterfaceIdentifier: String?

    /// Which network of its mode a Shared or Host Only VM joins. Bridged
    /// ignores it.
    var networkMembership: VMNetworkMembership

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

    // MARK: - Drag and Drop

    /// When `true`, files dragged onto this VM's display are sent to the guest
    /// agent, which writes them into the guest's Downloads folder.
    ///
    /// Independent of `clipboardSharingEnabled` — a drop never touches either
    /// pasteboard — and honored at runtime, so the display stops being a drag
    /// destination the moment it is switched off. Linux guests have no Kernova
    /// agent and ignore this flag.
    var dropFilesEnabled: Bool

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

    // MARK: - Input Devices

    /// Which pointing/keyboard device pair a macOS guest carries; ignored by
    /// Linux guests, which always take the USB pair.
    ///
    /// `.automatic` resolves through ``GuestInputDevices``. Applied at the
    /// next boot, like the rest of the device configuration.
    var inputDeviceMode: VMInputDeviceMode

    /// When the display hands system hot keys to the guest, backing
    /// `VZVirtualMachineView.capturesSystemKeys`.
    ///
    /// Which keys those are is the framework's to decide; this only says when
    /// it is asked to take them. Read on every observation pass rather than at
    /// boot, so both a change here and a fullscreen transition under
    /// ``VMSystemKeyForwarding/fullscreenOnly`` reach a running VM.
    var systemKeyForwarding: VMSystemKeyForwarding

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
    /// `nil` or empty both mean "use defaults" — see
    /// ``effectiveStorageDisks(layout:)``, the one place that synthesizes the
    /// main-disk entry a VM with no configured disks boots from.
    var storageDisks: [StorageDisk]?

    /// The disks this VM actually attaches: the configured list when non-empty,
    /// otherwise the synthesized main disk at the bundle's `Disk.asif`.
    func effectiveStorageDisks(layout: VMBundleLayout) -> [StorageDisk] {
        if let configured = storageDisks, !configured.isEmpty { return configured }
        return [StorageDisk.mainDisk(layout: layout)]
    }

    /// Assigns `disks`, storing `nil` for an empty list so `config.json` never
    /// carries an empty array.
    mutating func setStorageDisks(_ disks: [StorageDisk]) {
        storageDisks = disks.isEmpty ? nil : disks
    }

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

    /// The setup a first start runs before the guest can boot.
    ///
    /// The one spelling of "this start runs guest setup": the start dispatch,
    /// the Start control's wording and the unattended bring-up rule all read
    /// ``pendingGuestSetup`` rather than the stored contexts.
    enum PendingGuestSetup: Sendable, Equatable {
        case macOSInstall(MacOSInstallContext)
        case linuxImageDownload(LinuxInstallContext)
    }

    /// Pending macOS install plan from the creation wizard.
    ///
    /// Non-nil ⇔ this VM has never completed its initial boot: its presence
    /// routes `start(_:)` through the install pipeline. Cleared exactly once,
    /// after a successful install. Always `nil` for Linux guests.
    var installContext: MacOSInstallContext?

    /// The macOS account this VM still owes its guest, minus the password.
    ///
    /// Outlives ``installContext``: the install is over when the image lands,
    /// and the account is owed until a boot has spent the one window macOS
    /// reads it in — the boot chained onto a completed install, or the next
    /// Start when something interrupted the two. Retracted by
    /// ``VMLibrary/retractGuestAccount(_:)``, which is what every ending goes
    /// through.
    var pendingGuestAccount: GuestAccountIntent?

    /// Pending Linux installer-image download from the creation wizard.
    ///
    /// Non-nil ⇒ this VM has never completed its initial boot: its presence
    /// routes `start(_:)` through the download pipeline. Cleared exactly once,
    /// after the verified ISO is attached. Always `nil` for macOS guests, and
    /// for a Linux guest whose ISO the user picked off their own disk.
    var linuxInstallContext: LinuxInstallContext?

    // MARK: - Metadata

    var createdAt: Date

    /// The installer image this VM was set up from, or `nil` when Kernova has
    /// no record of one — a VM it did not install, or a Linux ISO the user
    /// picked off their own disk.
    var installedImage: InstalledImage?

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        name: String,
        guestOS: VMGuestOS,
        bootMode: VMBootMode,
        cpuCount: Int? = nil,
        memorySizeInGB: VMMemorySize? = nil,
        diskSizeInGB: Int? = nil,
        displayWidth: Int = 1920,
        displayHeight: Int = 1200,
        displayPPI: Int = 144,
        displaySizesToWindow: Bool = true,
        displayHiDPI: Bool = true,
        displayAutoResizes: Bool = true,
        networkEnabled: Bool = true,
        networkMode: VMNetworkMode = .shared,
        bridgedInterfaceIdentifier: String? = nil,
        networkMembership: VMNetworkMembership = .common,
        macAddress: String? = nil,
        clipboardSharingEnabled: Bool = false,
        clipboardPassthroughEnabled: Bool = false,
        dropFilesEnabled: Bool = true,
        serialSocketRelayEnabled: Bool = false,
        audioInputEnabled: Bool = false,
        audioOutputEnabled: Bool = true,
        inputDeviceMode: VMInputDeviceMode = .automatic,
        systemKeyForwarding: VMSystemKeyForwarding = .always,
        agentLogForwardingEnabled: Bool = false,
        lastSeenAgentVersion: String? = nil,
        lastSeenGuestOSVersion: String? = nil,
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
        pendingGuestAccount: GuestAccountIntent? = nil,
        linuxInstallContext: LinuxInstallContext? = nil,
        createdAt: Date = Date(),
        installedImage: InstalledImage? = nil
    ) {
        self.id = id
        self.name = name
        self.guestOS = guestOS
        self.bootMode = bootMode
        self.cpuCount = cpuCount ?? guestOS.defaultCPUCount
        self.memorySizeInGB = memorySizeInGB ?? guestOS.defaultMemorySize
        self.diskSizeInGB = diskSizeInGB ?? VMGuestOS.defaultDiskSizeInGB
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.displayPPI = displayPPI
        self.displaySizesToWindow = displaySizesToWindow
        self.displayHiDPI = displayHiDPI
        self.displayAutoResizes = displayAutoResizes
        self.networkEnabled = networkEnabled
        self.networkMode = networkMode
        self.bridgedInterfaceIdentifier = bridgedInterfaceIdentifier
        self.networkMembership = networkMembership
        self.macAddress = macAddress
        self.clipboardSharingEnabled = clipboardSharingEnabled
        self.clipboardPassthroughEnabled = clipboardPassthroughEnabled
        self.dropFilesEnabled = dropFilesEnabled
        self.serialSocketRelayEnabled = serialSocketRelayEnabled
        self.audioInputEnabled = audioInputEnabled
        self.audioOutputEnabled = audioOutputEnabled
        self.inputDeviceMode = inputDeviceMode
        self.systemKeyForwarding = systemKeyForwarding
        self.agentLogForwardingEnabled = agentLogForwardingEnabled
        self.lastSeenAgentVersion = lastSeenAgentVersion
        self.lastSeenGuestOSVersion = lastSeenGuestOSVersion
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
        self.pendingGuestAccount = pendingGuestAccount
        self.linuxInstallContext = linuxInstallContext
        self.createdAt = createdAt
        self.installedImage = installedImage
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
        self.memorySizeInGB = try c.decode(VMMemorySize.self, forKey: .memorySizeInGB)
        self.diskSizeInGB = try c.decode(Int.self, forKey: .diskSizeInGB)
        self.displayWidth = try c.decode(Int.self, forKey: .displayWidth)
        self.displayHeight = try c.decode(Int.self, forKey: .displayHeight)
        self.displayPPI = try c.decode(Int.self, forKey: .displayPPI)
        self.displaySizesToWindow = try c.decodeIfPresent(Bool.self, forKey: .displaySizesToWindow) ?? true
        self.displayHiDPI = try c.decodeIfPresent(Bool.self, forKey: .displayHiDPI) ?? true
        self.displayAutoResizes = try c.decodeIfPresent(Bool.self, forKey: .displayAutoResizes) ?? true
        self.networkEnabled = try c.decode(Bool.self, forKey: .networkEnabled)
        self.networkMode = try c.decodeIfPresent(VMNetworkMode.self, forKey: .networkMode) ?? .shared
        self.bridgedInterfaceIdentifier = try c.decodeIfPresent(
            String.self, forKey: .bridgedInterfaceIdentifier)
        self.networkMembership =
            try c.decodeIfPresent(VMNetworkMembership.self, forKey: .networkMembership) ?? .common
        self.macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
        self.clipboardSharingEnabled = try c.decode(Bool.self, forKey: .clipboardSharingEnabled)
        self.clipboardPassthroughEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .clipboardPassthroughEnabled) ?? false
        self.dropFilesEnabled = try c.decodeIfPresent(Bool.self, forKey: .dropFilesEnabled) ?? true
        self.serialSocketRelayEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .serialSocketRelayEnabled) ?? false
        self.audioInputEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioInputEnabled) ?? false
        self.audioOutputEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioOutputEnabled) ?? true
        self.inputDeviceMode =
            try c.decodeIfPresent(VMInputDeviceMode.self, forKey: .inputDeviceMode) ?? .automatic
        self.systemKeyForwarding =
            try c.decodeIfPresent(VMSystemKeyForwarding.self, forKey: .systemKeyForwarding)
            ?? .always
        self.agentLogForwardingEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentLogForwardingEnabled) ?? false
        self.lastSeenAgentVersion = try c.decodeIfPresent(String.self, forKey: .lastSeenAgentVersion)
        self.lastSeenGuestOSVersion = try c.decodeIfPresent(String.self, forKey: .lastSeenGuestOSVersion)
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
        self.pendingGuestAccount = try c.decodeIfPresent(
            GuestAccountIntent.self, forKey: .pendingGuestAccount)
        self.linuxInstallContext = try c.decodeIfPresent(
            LinuxInstallContext.self, forKey: .linuxInstallContext)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.installedImage = try c.decodeIfPresent(InstalledImage.self, forKey: .installedImage)
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

    // MARK: - Network mode

    /// The network this VM joins, or `nil` when it carries no device at all.
    ///
    /// The pair of fields behind it read as one choice, which is how every
    /// surface offers it.
    var effectiveNetworkMode: VMNetworkMode? {
        networkEnabled ? networkMode : nil
    }

    /// Puts the VM on `mode`, or takes its network device away with `nil`.
    ///
    /// A change that gives the VM a device mints its first address:
    /// a VM with none gets a fresh random one from VZ at every start, so the
    /// address the LAN sees — and any DHCP reservation keyed on it — would
    /// differ from one boot to the next. `bridgedInterfaceIdentifier` is left
    /// alone, so switching away from Bridged and back remembers the interface.
    ///
    /// A no-op when the VM is already on `mode`, so nothing is minted for a
    /// write that changes nothing.
    mutating func applyNetworkMode(_ mode: VMNetworkMode?) {
        guard mode != effectiveNetworkMode else { return }
        guard let mode else {
            networkEnabled = false
            return
        }
        networkEnabled = true
        networkMode = mode
        mintMACAddressIfNeeded()
    }

    /// The network this VM's device joins, `nil` when it carries none: two
    /// devices share a link exactly when they join equal networks.
    var joinedNetwork: VMJoinedNetwork? {
        guard networkEnabled else { return nil }
        guard let kind = VmnetNetworkKind(mode: networkMode) else { return .bridged }
        let owner: UUID? =
            switch networkMembership {
            case .common: nil
            case .isolated: id
            }
        return .vmnet(VmnetNetworkID(kind: kind, owner: owner))
    }

    /// Whether this VM's device joins a network of its own — what every
    /// surface reports as isolated.
    var joinsOwnNetwork: Bool { joinedNetwork?.isOwn ?? false }

    /// The membership this VM's device joins its network with, `nil` where no
    /// app-managed network is joined (no device, or Bridged).
    var effectiveNetworkMembership: VMNetworkMembership? {
        guard case .vmnet = joinedNetwork else { return nil }
        return networkMembership
    }

    /// Whether a saved state this VM holds restores after its device moves
    /// between its mode's common network and a network of its own — `false`
    /// where no app-managed network is joined.
    var savedStateSurvivesMembershipMove: Bool {
        effectiveNetworkMembership != nil
            && networkMode.savedStateRestoresOnAnotherNetworkOfThisMode
    }

    /// Gives a VM with no address of its own one, for the reason
    /// ``applyNetworkMode(_:)`` states.
    mutating func mintMACAddressIfNeeded() {
        guard macAddress == nil else { return }
        macAddress = GuestMACAddress.random()
    }

    // MARK: - Snapshot revert

    /// The configuration a revert to `captured` installs: everything the
    /// snapshot recorded, carrying this VM's identity across.
    ///
    /// Apple promises `VZVirtualMachine.restoreMachineStateFrom` only "a
    /// configuration compatible with the file" and defines that no further,
    /// so a settings edit made after the capture gives way for the saved state
    /// to load. Subtracting
    /// identity rather than listing the hardware to take back is what keeps a
    /// device added here from being silently dropped from a revert.
    func adoptingSnapshotState(_ captured: VMConfiguration) -> VMConfiguration {
        var restored = captured
        restored.id = id
        restored.name = name
        restored.createdAt = createdAt
        restored.hardwareModelData = hardwareModelData
        restored.machineIdentifierData = machineIdentifierData
        restored.genericMachineIdentifierData = genericMachineIdentifierData
        return restored
    }

    // MARK: - Cloning

    /// Returns a new configuration suitable for a cloned VM instance: a new
    /// `id`, creation date and name, with every device id kept.
    ///
    /// Platform identity fields (`macAddress`, `machineIdentifierData`,
    /// `genericMachineIdentifierData`) are left as the source's — the caller
    /// replaces them for a ``CloneOutcome/newMachine`` clone.
    func clonedForNewInstance(existingNames: [String]) -> VMConfiguration {
        var clone = self
        clone.id = UUID()
        clone.createdAt = Date()
        clone.name = Self.generateCloneName(baseName: name, existingNames: existingNames)

        // The clone copies the source bundle's post-install artifacts, so
        // preserving either install context would falsely mark it as awaiting
        // an initial boot — and the guest inside those artifacts has already
        // spent the one boot an account could have been created on.
        clone.installContext = nil
        clone.pendingGuestAccount = nil
        clone.linuxInstallContext = nil

        return clone
    }

    /// Generates a unique clone name by appending " Copy", " Copy 2", etc.
    static func generateCloneName(baseName: String, existingNames: [String]) -> String {
        UniqueName.firstAvailable(prefix: "\(baseName) Copy", existing: existingNames)
    }

    // MARK: - Computed

    var memorySizeInBytes: UInt64 {
        memorySizeInGB.bytes
    }

    /// The setup a first start runs before the guest can boot, or `nil` when a
    /// start boots the guest directly.
    ///
    /// The canonical signal that this VM has yet to complete its initial boot,
    /// and the one ``VMStatus/initialBoot`` is derived from. A configuration
    /// carrying both contexts answers with the macOS one, which is what the
    /// start dispatch runs.
    var pendingGuestSetup: PendingGuestSetup? {
        if let installContext { return .macOSInstall(installContext) }
        if let linuxInstallContext { return .linuxImageDownload(linuxInstallContext) }
        return nil
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

    /// Whether the stored resolution — what the VM boots at — reads as HiDPI.
    var displayResolutionIsHiDPI: Bool {
        guestOS.supportsDisplayDensity && DisplayBootSizing.isHiDPI(ppi: displayPPI)
    }

    /// The "looks like" size the UI states — half the stored pixel count while
    /// the stored resolution is HiDPI.
    var displayBaseSize: (width: Int, height: Int) {
        guard displayResolutionIsHiDPI else { return (displayWidth, displayHeight) }
        return (displayWidth / 2, displayHeight / 2)
    }

    /// The stored trio a "looks like" size of `width` × `height` produces —
    /// what every surface that lets a caller name a display size writes.
    mutating func setDisplayBaseSize(width: Int, height: Int) {
        displayResolution = displayResolution(base: width, height: height)
    }

    /// The "looks like" size `width` × `height` settles at once fitted to what
    /// this VM takes — the size ``setDisplayBaseSize(width:height:)`` stores.
    func fittedDisplayBaseSize(width: Int, height: Int) -> (width: Int, height: Int) {
        var fitted = self
        fitted.displayResolution = displayResolution(base: width, height: height)
        return fitted.displayBaseSize
    }

    private func displayResolution(base width: Int, height: Int) -> DisplayBootSizing.Resolution {
        DisplayBootSizing.resolution(base: width, height: height, hiDPI: displayResolutionIsHiDPI)
    }

    /// The "looks like" sizes this VM takes in either axis at its stored
    /// density.
    var displayBaseSizeBounds: InclusiveBounds<Int> {
        DisplayBootSizing.baseBounds(hiDPI: displayResolutionIsHiDPI)
    }

    // MARK: - Clipboard

    /// Whether passthrough actually runs: the flag alone leaves it inert,
    /// because it rides on the clipboard sharing that carries it.
    var clipboardPassthroughIsEffective: Bool {
        clipboardSharingEnabled && clipboardPassthroughEnabled
    }

    // MARK: - Removable Media

    static func removableMediaChanged(old: VMConfiguration, new: VMConfiguration) -> Bool {
        (old.removableMedia ?? []) != (new.removableMedia ?? [])
    }
}

// MARK: - External file references

extension VMConfiguration {
    /// Every user-picked path this configuration points at, projected into
    /// ``ExternalFileReference``.
    ///
    /// The single walk of the external fields: consumers filter it by
    /// ``ExternalFileReference/Kind`` instead of re-deriving their own subset.
    /// Internal disks are absent — they live inside the bundle, are addressed
    /// bundle-relative, and carry no bookmark.
    var externalFileReferences: [ExternalFileReference] {
        var references: [ExternalFileReference] = []
        if let kernelPath {
            references.append(
                ExternalFileReference(
                    id: singletonReferenceID(seed: "kernel"), kind: .kernel, label: "Kernel",
                    path: kernelPath, bookmark: kernelBookmark))
        }
        if let initrdPath {
            references.append(
                ExternalFileReference(
                    id: singletonReferenceID(seed: "initrd"), kind: .initrd,
                    label: "Initial RAM Disk", path: initrdPath, bookmark: initrdBookmark))
        }
        for disk in storageDisks ?? [] where !disk.isInternal {
            references.append(
                ExternalFileReference(
                    id: disk.id, kind: .storageDisk, label: disk.label, path: disk.path,
                    bookmark: disk.bookmark))
        }
        for item in removableMedia ?? [] {
            references.append(
                ExternalFileReference(
                    id: item.id, kind: .removableMedia, label: item.label, path: item.path,
                    bookmark: item.bookmark))
        }
        for directory in sharedDirectories ?? [] {
            references.append(
                ExternalFileReference(
                    id: directory.id, kind: .sharedDirectory, label: directory.displayName,
                    path: directory.path, bookmark: directory.bookmark))
        }
        if let localIPSWPath = installContext?.localIPSWPath {
            references.append(
                ExternalFileReference(
                    id: singletonReferenceID(seed: "local-ipsw"), kind: .localIPSW,
                    label: "Installer Image", path: localIPSWPath,
                    bookmark: installContext?.localIPSWBookmark))
        }
        return references
    }

    /// Writes a resolved path and freshly minted bookmark back to the field
    /// `reference` was projected from.
    ///
    /// A list entry the id no longer matches — removed between the projection
    /// and the write-back — is a no-op.
    mutating func healExternalReference(
        _ reference: ExternalFileReference, movedTo path: String, bookmark: Data
    ) {
        switch reference.kind {
        case .kernel:
            kernelPath = path
            kernelBookmark = bookmark
        case .initrd:
            initrdPath = path
            initrdBookmark = bookmark
        case .storageDisk:
            guard let index = storageDisks?.firstIndex(where: { $0.id == reference.id })
            else { return }
            storageDisks?[index].path = path
            storageDisks?[index].bookmark = bookmark
        case .removableMedia:
            guard let index = removableMedia?.firstIndex(where: { $0.id == reference.id })
            else { return }
            removableMedia?[index].path = path
            removableMedia?[index].bookmark = bookmark
        case .sharedDirectory:
            guard let index = sharedDirectories?.firstIndex(where: { $0.id == reference.id })
            else { return }
            sharedDirectories?[index].path = path
            sharedDirectories?[index].bookmark = bookmark
        case .localIPSW:
            installContext?.localIPSWPath = path
            installContext?.localIPSWBookmark = bookmark
        }
    }

    /// Identity for a kind a configuration holds at most one of, seeded on this
    /// configuration so successive projections agree on it.
    private func singletonReferenceID(seed: String) -> UUID {
        StableID.uuid(seed: "\(id.uuidString)\u{0}\(seed)")
    }
}

// MARK: - Effective guest version

extension VMConfiguration {
    /// The best available reading of what macOS the guest is running, or `nil`
    /// when nothing has vouched for one.
    ///
    /// ``lastSeenGuestOSVersion`` wins: the agent rewrites it whenever the
    /// guest reports something new, so it survives an in-guest upgrade that
    /// leaves ``installedImage`` describing a release no longer installed. It
    /// is peer-supplied free text, though, so a report that parses to nothing
    /// falls through to the install record rather than erasing its vote.
    var effectiveGuestMacOSVersion: MacOSVersion? {
        if let reported = lastSeenGuestOSVersion,
            let numeric = KernovaOSVersion.numericVersion(in: reported),
            let version = MacOSVersion(numeric)
        {
            return version
        }
        if case .macOSRestoreImage(let version, _) = installedImage {
            return MacOSVersion(version)
        }
        return nil
    }

    /// Whether a clone of this VM can be a New Machine — `false` for a guest
    /// known to run macOS 12 or earlier, which does not boot under a new
    /// machine identifier: 12.7.6 stops at "Authentication is required to
    /// verify startup disk" and 12.0.1 hangs on a black display, as observed
    /// in #698.
    var offersNewMachineClone: Bool {
        guard guestOS == .macOS, let version = effectiveGuestMacOSVersion else { return true }
        return version.isAtLeast(MacOSVersion(major: 13, minor: 0))
    }

    /// Whether the guest can write to a disk outside the bundle: an external
    /// storage disk or removable media not marked read-only — files no
    /// snapshot or clone copies (``VMBundleMachineFiles/capturedRelativePaths(for:layout:)``).
    var writesOutsideBundle: Bool {
        (storageDisks ?? []).contains { !$0.isInternal && !$0.readOnly }
            || (removableMedia ?? []).contains { !$0.readOnly }
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

    /// The name a macOS guest mounts this folder by, fixed when the share is
    /// added so no later change to the list, or to `path`, renames it.
    let mountName: String

    /// A share mounted by `mountName`, by default the folder's own name.
    init(
        id: UUID = UUID(), path: String, readOnly: Bool = false, bookmark: Data? = nil,
        mountName: String? = nil
    ) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
        self.bookmark = bookmark
        self.mountName = mountName ?? URL(fileURLWithPath: path).lastPathComponent
    }

    /// A new share `id` of the folder at `path`, mounted by a name none of
    /// `directories` holds: the folder's own, or the same prefixed with the
    /// share's id.
    init(
        adding path: String, id: UUID, readOnly: Bool, bookmark: Data?,
        to directories: [SharedDirectory]
    ) {
        let taken = Set(directories.map(\.mountName))
        let name = URL(fileURLWithPath: path).lastPathComponent
        let candidates = [
            name, "\(id.uuidString.prefix(8))-\(name)", "\(id.uuidString)-\(name)",
        ]
        self.init(
            id: id, path: path, readOnly: readOnly, bookmark: bookmark,
            mountName: candidates.first { !taken.contains($0) } ?? candidates[2])
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .path)
        self.init(
            id: try c.decode(UUID.self, forKey: .id), path: path,
            readOnly: try c.decode(Bool.self, forKey: .readOnly),
            bookmark: try c.decodeIfPresent(Data.self, forKey: .bookmark),
            mountName: try c.decodeIfPresent(String.self, forKey: .mountName))
    }

    /// The last path component, used as the display name in the UI and as the share name in VirtioFS.
    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
