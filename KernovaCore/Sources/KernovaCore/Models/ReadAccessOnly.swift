import Foundation

/// Why an entry's Read Only stays on whatever its setting — its bookmark grants
/// reading alone (``FileBookmark/Access/readOnly``) — and what lifts that: what
/// Settings shows beside the entry's Read Only switch, and what a request to
/// turn it off is refused with.
package struct ReadAccessOnly: Sendable, Equatable {
    /// Why, naming the entry.
    package let reason: String
    /// What gives the entry a bookmark that grants writing: a new pick of the
    /// file, which only attaching it again makes.
    package let remedy: String

    /// The notice for an attached disk image named `label`, listed under
    /// `section` in Settings.
    fileprivate init(file label: String, removing entry: String, section: String) {
        reason =
            "Kernova has read access only to “\(label)”, because the file couldn’t be written to when it was attached."
        remedy =
            "To turn Read Only off, make the file writable, then remove \(entry) and attach the file again with "
            + "Attach Disk… in Settings, under \(section)."
    }

    /// The notice for a shared folder named `name`.
    fileprivate init(folder name: String) {
        reason =
            "Kernova has read access only to “\(name)”, because the folder couldn’t be written to when it was shared."
        remedy =
            "To turn Read Only off, make the folder writable, then remove the share and add the folder again with "
            + "Add Shared Directory… in Settings, under Shared Directories."
    }

    /// The notice for a share of the folder at `path` asked for writable, whose
    /// bookmark was just made granting reading alone.
    init(sharingWritable path: String) {
        reason = "Kernova has read access only to “\(path)”, because the folder can’t be written to."
        remedy = "Share it as read only, or make the folder writable and share it again."
    }

    /// The whole notice, as one refusal states it.
    package var message: String { "\(reason) \(remedy)" }
}

extension StorageDisk {
    /// Why the disk stays Read Only, `nil` unless its bookmark grants reading
    /// alone.
    package var readAccessOnly: ReadAccessOnly? {
        guard bookmark?.access == .readOnly else { return nil }
        return ReadAccessOnly(file: label, removing: "the disk", section: "Storage Disks")
    }
}

extension RemovableMediaItem {
    /// Why the medium stays Read Only, `nil` unless its bookmark grants
    /// reading alone.
    package var readAccessOnly: ReadAccessOnly? {
        guard bookmark?.access == .readOnly else { return nil }
        return ReadAccessOnly(file: label, removing: "it", section: "Removable Media")
    }
}

extension SharedDirectory {
    /// Why the share stays Read Only, `nil` unless its bookmark grants reading
    /// alone.
    package var readAccessOnly: ReadAccessOnly? {
        guard bookmark?.access == .readOnly else { return nil }
        return ReadAccessOnly(folder: name)
    }
}
