import Foundation

/// Bus class for a `StorageDisk` entry.
///
/// Devices on `vzConfig.storageDevices` can be either virtio-block or USB
/// mass storage; both are valid boot media on EFI, but the guest sees them
/// in different namespaces (`/dev/vd*` vs `/dev/sd*` on Linux). Installer
/// media (`.iso`, `.dmg`) goes on the USB bus so it can be reordered ahead
/// of the main disk for boot without shifting the main disk's `/dev/vda`
/// letter assignment.
enum StorageDiskKind: String, Codable, Sendable, Equatable {
    case virtio
    case usbMassStorage
}

/// A disk attached on `vzConfig.storageDevices`.
///
/// Position in `VMConfiguration.storageDisks` is array position on the VZ
/// configuration, which EFI uses for boot order. Includes both the
/// bundle's primary disk (`Disk.asif`) and any user-added internal /
/// external disks or installer images — all rendered identically in the UI.
struct StorageDisk: Codable, Sendable, Equatable {
    var id: UUID
    /// Bundle-relative for internal disks (e.g. `"Disk.asif"`,
    /// `"AdditionalDisks/<id>.asif"`); absolute for external disks.
    var path: String
    var readOnly: Bool
    var label: String
    /// When `true`, `path` is bundle-relative and the file is owned by the bundle.
    ///
    /// Removing the entry can optionally trash the file.
    var isInternal: Bool
    /// Bus class for this disk.
    ///
    /// Set at add-time from the file extension via ``defaultKind(forPath:)``;
    /// persisted so renaming the file on disk doesn't silently change
    /// guest-side device naming.
    var kind: StorageDiskKind

    /// App-scoped security bookmark for `path`, minted from the user's
    /// open-panel grant so the sandboxed app can reopen the file across
    /// launches.
    ///
    /// Only meaningful for external disks; `nil` for internal
    /// (bundle-relative) disks, for configs written before the sandbox
    /// adoption, and when bookmark creation failed — resolution then falls
    /// back to the raw path, surfacing the existing missing-file UX when
    /// the sandbox denies it.
    var bookmark: Data?

    init(
        id: UUID = UUID(),
        path: String,
        readOnly: Bool = false,
        label: String? = nil,
        isInternal: Bool = false,
        kind: StorageDiskKind? = nil,
        bookmark: Data? = nil
    ) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
        self.label = label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.isInternal = isInternal
        self.kind = kind ?? Self.defaultKind(forPath: path)
        self.bookmark = bookmark
    }

    /// Picks the bus class implied by the file extension.
    ///
    /// `.iso` and `.dmg` default to `.usbMassStorage` — still attached on
    /// `vzConfig.storageDevices` (and therefore bootable by EFI), but as
    /// `VZUSBMassStorageDeviceConfiguration` rather than virtio. The
    /// payoff is `/dev/vda` stability: inserting an installer ahead of
    /// the main disk in the boot order doesn't shift the main disk's
    /// Linux device letter. Everything else defaults to `.virtio`
    /// (the conventional permanent-disk bus).
    ///
    /// This is the in-`storageDevices` USB path — distinct from
    /// `RemovableMediaItem`, which lives on the XHCI controller's
    /// `usbDevices` list and is not in the EFI boot path.
    static func defaultKind(forPath path: String) -> StorageDiskKind {
        let ext = (path as NSString).pathExtension.lowercased()
        return (ext == "iso" || ext == "dmg") ? .usbMassStorage : .virtio
    }

    /// A label derived from `base` that doesn't collide with `existingLabels`.
    ///
    /// Returns `base` when it's free, otherwise the first available
    /// `"<base> 2"`, `"<base> 3"`, … Mirrors
    /// ``VMConfiguration/generateCloneName(baseName:existingNames:)`` but with a
    /// bare numeric suffix (no "Copy"), used to give machine-created disks
    /// distinct default labels so same-size disks are tellable apart out of the
    /// box. Case-sensitive exact match; only machine-generated defaults are
    /// uniqued — explicit user renames are left exactly as typed.
    static func uniqueLabel(base: String, existingLabels: [String]) -> String {
        UniqueName.firstAvailable(prefix: base, existing: existingLabels)
    }

    /// Display string used in the UI subtitle.
    var displayPath: String {
        isInternal ? "In-bundle disk image" : path
    }

    /// Block device identifier exposed to virtio-block guests.
    ///
    /// Truncated to 20 ASCII characters per VZ's limit. Visible in Linux
    /// guests at `/dev/disk/by-id/virtio-<identifier>`. Unused for USB
    /// mass storage entries.
    var blockDeviceIdentifier: String {
        String(id.uuidString.prefix(20))
    }
}

/// A USB mass storage device on the XHCI controller's `usbDevices` list.
///
/// Hot-pluggable while the VM is running. **Not in the EFI boot path:**
/// `VZEFIBootLoader` only walks `vzConfig.storageDevices`, so XHCI
/// `usbDevices` are invisible to firmware boot selection. Use a
/// `StorageDisk` with `kind == .usbMassStorage` for bootable removable
/// media. Each item's `id` becomes the `VZUSBMassStorageDeviceConfiguration.uuid`
/// so save-state restore can match the configured item against the
/// saved-state device list.
struct RemovableMediaItem: Codable, Sendable, Equatable {
    var id: UUID
    var path: String
    var readOnly: Bool
    var label: String

    /// App-scoped security bookmark for `path` (always an external,
    /// user-picked file); see ``StorageDisk/bookmark`` for the nil semantics.
    var bookmark: Data?

    init(
        id: UUID = UUID(),
        path: String,
        readOnly: Bool = true,
        label: String? = nil,
        bookmark: Data? = nil
    ) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
        self.label = label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.bookmark = bookmark
    }
}

/// A storage disk or removable media item that lives *outside* the VM
/// bundle and is therefore not trashed automatically when the bundle is
/// trashed.
///
/// Surfaces in the delete confirmation sheet so the user can opt to send
/// these files to Trash alongside the VM. `sharedWithVMNames` is non-empty
/// when one or more other VMs in the library reference the same path —
/// the UI uses that to warn before the user opts in to trashing a shared
/// file (e.g., a Windows installer ISO referenced by several VMs).
///
/// `isMissing` is `true` when the backing file no longer resolves on disk
/// (deleted/moved out-of-band, or on an ejected volume). The delete sheet
/// renders such rows as inert — there is nothing left to trash — instead of
/// implying an action that would silently no-op.
struct ExternalAttachment: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case storageDisk
        case removableMedia
    }

    let id: UUID
    let kind: Kind
    let label: String
    let path: String
    let sharedWithVMNames: [String]
    /// `true` when `path` no longer resolves to a file on disk.
    let isMissing: Bool

    var isShared: Bool { !sharedWithVMNames.isEmpty }
}
