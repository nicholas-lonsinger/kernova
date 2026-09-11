import Foundation

/// One change to a VM's storage-disk list.
///
/// One verb with an enum argument, the shape ``StopDisposition`` establishes: a
/// refusal that reads out what a VM accepts names "Edit Storage Disks" once
/// rather than six near-identical entries.
///
/// Attaching a disk the user picked is deliberately absent — a pick carries a
/// security-scoped bookmark only an in-process open panel can mint.
public enum StorageDiskEdit: Codable, Sendable, Hashable {
    /// Writes a new sparse image inside the VM's bundle and appends it.
    case create(sizeInGB: Int)
    /// Drops the entry, and with `trashFile` the file behind it.
    case remove(disk: UUID, trashFile: Bool, confirmed: Bool)
    /// Replaces the disk's user-facing label.
    case rename(disk: UUID, newLabel: String)
    /// Replaces the disk's free-form note.
    case setNotes(disk: UUID, notes: String)
    /// Marks the disk read-only, or writable again.
    case setReadOnly(disk: UUID, readOnly: Bool)
    /// Rewrites the boot order; disks the list does not name keep their
    /// relative order behind those it does.
    case reorder(order: [UUID])
}

/// One change to a VM's hot-pluggable removable-media list.
///
/// Attaching a picked file and creating a disk at a chosen destination are
/// absent for the reason ``StorageDiskEdit`` states — both need a live panel
/// grant.
public enum RemovableMediaEdit: Codable, Sendable, Hashable {
    /// Drops the entry, and with `trashFile` the file behind it.
    case remove(item: UUID, trashFile: Bool, confirmed: Bool)
    /// Drops the entry and keeps the file — what a running guest sees as an
    /// eject.
    case eject(item: UUID)
    /// Replaces the medium's user-facing label.
    case rename(item: UUID, newLabel: String)
    /// Replaces the medium's free-form note.
    case setNotes(item: UUID, notes: String)
    /// Marks the medium read-only, or writable again.
    case setReadOnly(item: UUID, readOnly: Bool)
}

/// One change to a VM's shared-directory list.
///
/// A share carries no label or note of its own: its name is the folder's, which
/// is also what the guest mounts by — so `path` identifies a share as well as
/// its id does, and is what a client with no ids to hand names one by.
///
/// Adding is on the wire where a picked disk is not: the app obtains the grant
/// for `path` and mints the bookmark, which a sandboxed client holds nothing to
/// hand over.
public enum SharedDirectoryEdit: Codable, Sendable, Hashable {
    /// Shares `path` with the guest, skipping a folder the VM already shares.
    case add(path: String, readOnly: Bool)
    /// Drops the entry. The folder itself is never touched.
    case remove(directory: UUID)
    /// Drops the entry the folder at `path` fills.
    case removePath(path: String)
    /// Marks the share read-only, or writable again.
    case setReadOnly(directory: UUID, readOnly: Bool)
}

/// One change to the USB accessories a VM's guest holds.
///
/// Both sides name a device the caller got from a list: `accessory` is an
/// `AAUSBAccessory.registryID` from the available list, and `device` the
/// attachment UUID from the attached one. Neither survives a replug or a
/// restart, which is why nothing persists either.
public enum USBAccessoryEdit: Codable, Sendable, Hashable {
    /// Passes the accessory through to the guest.
    case attach(accessory: UInt64)
    /// Takes the accessory back off the guest.
    case detach(device: UUID)
}

/// What to do with the bundled guest-agent installer disk.
public enum GuestAgentDiskEdit: String, Codable, Sendable, Hashable, CaseIterable {
    /// Put the installer image in front of the guest.
    case mount
    /// Take it away again.
    case unmount
}
