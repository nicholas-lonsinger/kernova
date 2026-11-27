import Foundation

/// Why an entry's Read Only stays on whatever its setting — its bookmark grants
/// reading alone (``FileBookmark/Access/readOnly``) — and what asks for write
/// access again: what Settings shows beside the entry's Read Only switch, and
/// what a request to turn it off is refused with.
package struct ReadAccessOnly: Sendable, Equatable {
    /// Why, naming the entry.
    package let reason: String
    /// What asks the system for a bookmark that grants writing: a new pick of
    /// the file, which only attaching it again makes, named by the controls
    /// that do it.
    package let remedy: String

    /// The whole notice, as one refusal states it.
    package var message: String { "\(reason) \(remedy)" }
}

extension ReadAccessOnly {
    /// The reason for a disk image named `label`: the system refuses a
    /// read-write bookmark for a file the process can only read
    /// (docs/research/2026-11-18-pasteboard-file-grants.md, finding 15).
    fileprivate static func fileReason(_ label: String) -> String {
        "Kernova has read access only to “\(label)”, because the file couldn’t be written to when it was attached."
    }

    /// The reason for a folder at, or named, `folder`. No cause is named:
    /// folders of mode 0555, locked, and on a read-only volume each got a
    /// read-write bookmark (unsandboxed, macOS 27.2.1, 2026-11-26).
    fileprivate static func folderReason(_ folder: String) -> String {
        "Kernova has read access only to “\(folder)”."
    }

    /// The notice for a share of the folder at `path` asked for writable, whose
    /// bookmark was just made granting reading alone.
    init(sharingWritable path: String) {
        self.init(reason: Self.folderReason(path), remedy: "Share it as read only.")
    }
}

extension StorageDisk {
    /// Why the disk stays Read Only, `nil` unless its bookmark grants reading
    /// alone.
    package var readAccessOnly: ReadAccessOnly? {
        guard bookmark?.access == .readOnly else { return nil }
        return ReadAccessOnly(
            reason: ReadAccessOnly.fileReason(label),
            remedy:
                "To turn Read Only off, make the file writable, then remove the disk with Remove… and Remove "
                + "from VM, and attach the file again with Attach Disk… in Settings, under Storage Disks.")
    }
}

extension RemovableMediaItem {
    /// Why the medium stays Read Only, `nil` unless its bookmark grants
    /// reading alone.
    package var readAccessOnly: ReadAccessOnly? {
        guard bookmark?.access == .readOnly else { return nil }
        return ReadAccessOnly(
            reason: ReadAccessOnly.fileReason(label),
            remedy:
                "To turn Read Only off, make the file writable, then Eject the disk and attach the file again "
                + "with Attach Disk… in Settings, under Removable Media.")
    }
}

extension SharedDirectory {
    /// Why the share stays Read Only, `nil` unless its bookmark grants reading
    /// alone.
    package var readAccessOnly: ReadAccessOnly? {
        guard bookmark?.access == .readOnly else { return nil }
        return ReadAccessOnly(
            reason: ReadAccessOnly.folderReason(name),
            remedy:
                "Ejecting the share and adding the folder again with Add Shared Directory… in Settings, under "
                + "Shared Directories, asks for write access again.")
    }
}
