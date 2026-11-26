import AppIntents
import Foundation
import KernovaCommandModel

/// One disk a VM attaches, as a Shortcut reads it.
///
/// Built from a ``StorageDiskSummary`` alone. Transient because no intent
/// takes a disk as a parameter: a disk only ever leaves
/// ``FindStorageDisksIntent`` as a value, so there is no identifier to
/// re-resolve.
struct StorageDiskEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Disk")

    @Property(title: "Name")
    var label: String

    /// The bus the guest sees the disk on.
    @Property(title: "Kind")
    var kind: StorageDiskKindChoice

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

    /// The entity `summary` describes, accounting for each
    /// ``StorageDiskSummary/Field``.
    init(_ summary: StorageDiskSummary) {
        for field in StorageDiskSummary.Field.allCases {
            switch field {
            // What a storage-disk edit names a disk by, and no action here takes one.
            case .id: break
            case .label: label = summary.label
            case .kind: kind = StorageDiskKindChoice(summary.kind)
            case .readOnly: readOnly = summary.readOnly
            case .path: path = summary.path
            case .notes: notes = summary.notes
            case .capacityBytes: capacityBytes = summary.capacityBytes.map { Int(clamping: $0) }
            case .usedBytes: usedBytes = summary.usedBytes.map { Int(clamping: $0) }
            }
        }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(label)",
            subtitle: capacityBytes.map { "\(DataFormatters.formatBytes(UInt64($0)))" })
    }
}

/// The bus the guest sees a ``StorageDiskEntity`` on, titled as the Storage
/// settings read it.
///
/// Mirrors ``StorageDiskKind`` rather than conforming it, for the reason
/// ``VMStopMethod`` gives. ``init(_:)`` is exhaustive over the kinds, so a new
/// one fails to build here rather than reaching Shortcuts unnamed.
enum StorageDiskKindChoice: String, AppEnum {
    case virtio
    case usbMassStorage

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Disk Kind")

    static let caseDisplayRepresentations: [StorageDiskKindChoice: DisplayRepresentation] = [
        .virtio: "Virtio block",
        .usbMassStorage: "USB mass storage",
    ]

    /// The case naming `kind`.
    init(_ kind: StorageDiskKind) {
        self =
            switch kind {
            case .virtio: .virtio
            case .usbMassStorage: .usbMassStorage
            }
    }
}
