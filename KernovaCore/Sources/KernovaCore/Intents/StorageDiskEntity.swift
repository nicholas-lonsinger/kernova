import AppIntents
import Foundation
import KernovaCommandModel

/// One disk a VM attaches, as a Shortcut reads it.
///
/// Built from a ``StorageDiskSummary`` and nothing else, so what this surface
/// shows can never drift from what the command core reads. Transient because
/// no intent takes a disk as a parameter: a disk only ever leaves
/// ``FindStorageDisksIntent`` as a value, so there is no identifier to
/// re-resolve.
struct StorageDiskEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Disk")

    @Property(title: "Name")
    var label: String

    /// The bus the guest sees the disk on, as its stable wire name.
    @Property(title: "Kind")
    var kind: String

    @Property(title: "Read Only")
    var readOnly: Bool

    @Property(title: "Path")
    var path: String

    @Property(title: "Notes")
    var notes: String

    /// The disk's size as the guest sees it, `nil` when the image can't be
    /// read. Narrowed from the core's `UInt64`, which is not a value Shortcuts
    /// carries.
    @Property(title: "Capacity in Bytes")
    var capacityBytes: Int?

    /// What the image takes on its volume, `nil` when the image can't be read.
    @Property(title: "Used Space in Bytes")
    var usedBytes: Int?

    init() {}

    init(_ summary: StorageDiskSummary) {
        self.label = summary.label
        self.kind = summary.kind
        self.readOnly = summary.readOnly
        self.path = summary.path
        self.notes = summary.notes
        self.capacityBytes = summary.capacityBytes.map { Int(clamping: $0) }
        self.usedBytes = summary.usedBytes.map { Int(clamping: $0) }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(label)",
            subtitle: capacityBytes.map { "\(DataFormatters.formatBytes(UInt64($0)))" })
    }
}
