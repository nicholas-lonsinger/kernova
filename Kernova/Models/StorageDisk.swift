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
struct StorageDisk: Codable, Sendable, Equatable, Identifiable {
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

    init(
        id: UUID = UUID(),
        path: String,
        readOnly: Bool = false,
        label: String? = nil,
        isInternal: Bool = false,
        kind: StorageDiskKind? = nil
    ) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
        self.label = label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.isInternal = isInternal
        self.kind = kind ?? Self.defaultKind(forPath: path)
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
struct RemovableMediaItem: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var path: String
    var readOnly: Bool
    var label: String

    init(
        id: UUID = UUID(),
        path: String,
        readOnly: Bool = true,
        label: String? = nil
    ) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
        self.label = label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
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
struct ExternalAttachment: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case storageDisk
        case removableMedia
    }

    let id: UUID
    let kind: Kind
    let label: String
    let path: String
    let sharedWithVMNames: [String]

    var isShared: Bool { !sharedWithVMNames.isEmpty }
}
