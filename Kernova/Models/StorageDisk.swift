import CryptoKit
import Foundation

/// Bus class for a `StorageDisk` entry.
///
/// Both virtio-block and USB mass storage are valid boot media on EFI, but the
/// guest sees them in different namespaces (`/dev/vd*` vs `/dev/sd*` on Linux).
enum StorageDiskKind: String, Codable, Sendable, Equatable {
    case virtio
    case usbMassStorage
}

/// A disk attached on `vzConfig.storageDevices`.
///
/// Covers the bundle's primary disk (`Disk.asif`) and any user-added internal
/// or external disks and installer images.
struct StorageDisk: Codable, Sendable, Equatable {
    var id: UUID
    /// Bundle-relative for internal disks (e.g. `"Disk.asif"`,
    /// `"AdditionalDisks/<id>.asif"`); absolute for external disks.
    var path: String
    var readOnly: Bool
    var label: String
    /// When `true`, `path` is bundle-relative and the file is owned by the bundle.
    var isInternal: Bool
    /// Bus class for this disk.
    ///
    /// Set at add-time from the file extension and persisted, so renaming the
    /// file on disk doesn't silently change guest-side device naming.
    var kind: StorageDiskKind

    /// App-scoped security bookmark for `path`, minted from the user's
    /// open-panel grant so the sandboxed app can reopen the file across
    /// launches.
    ///
    /// Only meaningful for external disks; `nil` for internal (bundle-relative)
    /// disks and when bookmark creation failed — resolution then falls back to
    /// the raw path, surfacing the missing-file UX if the sandbox denies it.
    var bookmark: Data?

    /// Free-form user note, empty when none was entered.
    var notes: String

    init(
        id: UUID = UUID(),
        path: String,
        readOnly: Bool = false,
        label: String? = nil,
        isInternal: Bool = false,
        kind: StorageDiskKind? = nil,
        bookmark: Data? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
        self.label = label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.isInternal = isInternal
        self.kind = kind ?? Self.defaultKind(forPath: path)
        self.bookmark = bookmark
        self.notes = notes
    }

    // Custom `init(from:)` for `notes`: a `decode` of a non-optional field
    // fails the whole `VMConfiguration` decode when the key is absent, which a
    // config written before this field existed always is.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.path = try c.decode(String.self, forKey: .path)
        self.readOnly = try c.decode(Bool.self, forKey: .readOnly)
        self.label = try c.decode(String.self, forKey: .label)
        self.isInternal = try c.decode(Bool.self, forKey: .isInternal)
        self.kind = try c.decode(StorageDiskKind.self, forKey: .kind)
        self.bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    /// Picks the bus class implied by the file extension.
    ///
    /// `.iso` and `.dmg` default to `.usbMassStorage` — still on
    /// `vzConfig.storageDevices` and bootable by EFI, but as
    /// `VZUSBMassStorageDeviceConfiguration`, so inserting an installer ahead of
    /// the main disk in the boot order doesn't shift the main disk's Linux
    /// device letter. Everything else defaults to `.virtio`.
    static func defaultKind(forPath path: String) -> StorageDiskKind {
        let ext = (path as NSString).pathExtension.lowercased()
        return (ext == "iso" || ext == "dmg") ? .usbMassStorage : .virtio
    }

    /// A label derived from `base` that doesn't collide with `existingLabels`.
    ///
    /// Returns `base` when it's free, otherwise the first available
    /// `"<base> 2"`, `"<base> 3"`, … Only machine-generated defaults are
    /// uniqued; explicit user renames are left exactly as typed.
    static func uniqueLabel(base: String, existingLabels: [String]) -> String {
        UniqueName.firstAvailable(prefix: base, existing: existingLabels)
    }

    /// Synthesizes the default main-disk entry for a VM whose `storageDisks`
    /// list is empty or absent.
    ///
    /// Without stable identity, a lookup-by-id for this disk would miss the
    /// row the user just clicked — silently no-op'ing the entry removal while
    /// still trashing the underlying file.
    static func mainDisk(layout: VMBundleLayout) -> StorageDisk {
        let stableMainDiskID = stableID(seed: layout.bundleURL.path)
        return StorageDisk(
            id: stableMainDiskID,
            path: layout.diskImageURL.lastPathComponent,
            readOnly: false,
            label: "Main Disk",
            isInternal: true,
            kind: .virtio
        )
    }

    /// A UUID fixed by `seed`.
    static func stableID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    /// Display string used in the UI subtitle.
    var displayPath: String {
        isInternal ? "In-bundle disk image" : path
    }

    /// Block device identifier exposed to virtio-block guests.
    ///
    /// Truncated to 20 ASCII characters per VZ's limit; unused for USB mass
    /// storage entries.
    var blockDeviceIdentifier: String {
        String(id.uuidString.prefix(20))
    }
}

/// A USB mass storage device on the XHCI controller's `usbDevices` list.
///
/// Hot-pluggable while the VM is running. **Not in the EFI boot path:**
/// `VZEFIBootLoader` only walks `vzConfig.storageDevices`, so use a
/// `StorageDisk` with `kind == .usbMassStorage` for bootable removable media.
/// Each item's `id` becomes the `VZUSBMassStorageDeviceConfiguration.uuid` for
/// save-state matching.
struct RemovableMediaItem: Codable, Sendable, Equatable {
    var id: UUID
    var path: String
    var readOnly: Bool
    var label: String

    /// App-scoped security bookmark for `path` (always an external,
    /// user-picked file); see ``StorageDisk/bookmark`` for the nil semantics.
    var bookmark: Data?

    /// Free-form user note, empty when none was entered.
    var notes: String

    init(
        id: UUID = UUID(),
        path: String,
        readOnly: Bool = true,
        label: String? = nil,
        bookmark: Data? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
        self.label = label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.bookmark = bookmark
        self.notes = notes
    }

    // Custom `init(from:)` for `notes`: a `decode` of a non-optional field
    // fails the whole `VMConfiguration` decode when the key is absent, which a
    // config written before this field existed always is.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.path = try c.decode(String.self, forKey: .path)
        self.readOnly = try c.decode(Bool.self, forKey: .readOnly)
        self.label = try c.decode(String.self, forKey: .label)
        self.bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

/// A storage disk or removable media item that lives *outside* the VM
/// bundle and is therefore not trashed automatically when the bundle is
/// trashed.
///
/// Surfaces in the delete confirmation sheet so the user can opt to send these
/// files to Trash alongside the VM. `sharedWithVMNames` is non-empty when other
/// VMs reference the same path, so the UI can warn before trashing a shared
/// file.
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
