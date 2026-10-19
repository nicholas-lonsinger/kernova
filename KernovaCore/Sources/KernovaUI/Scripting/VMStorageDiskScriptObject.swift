import Cocoa
import KernovaCore
import KernovaKit
import KernovaLogging

/// One disk a VM attaches, as the scripting dictionary's `storage disk`.
///
/// A snapshot of one measured read, like ``VMScriptObject``: the VM rebuilds
/// its list on every specifier evaluation. Every property is read only.
@MainActor
@objc(VMStorageDiskScriptObject)
package final class VMStorageDiskScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMStorageDiskScriptObject")

    /// The read every property answers from.
    private let disk: StorageDiskSummary
    /// The VM that attaches it.
    private let vm: UUID

    init(_ disk: StorageDiskSummary, of vm: UUID) {
        self.disk = disk
        self.vm = vm
    }

    // MARK: - Properties

    @objc var uniqueID: String { disk.id.uuidString }

    @objc var name: String { disk.label }

    /// The `storage disk kind` enumerator for the bus the guest sees the disk
    /// on, as the Apple event code the dictionary gives it.
    ///
    /// `missing value` for a kind from no vocabulary this app writes, which is
    /// a programming error rather than a disk a script can provoke.
    @objc var kind: NSNumber? {
        guard let kind = VMScriptStorageDiskKind(wireName: disk.kind) else {
            #log(
                Self.logger, .fault,
                "Storage disk kind '\(self.disk.kind, privacy: .public)' has no scripting term")
            assertionFailure("Storage disk kind '\(disk.kind)' has no scripting term")
            return nil
        }
        return NSNumber(value: kind.code)
    }

    @objc var readOnly: Bool { disk.readOnly }

    @objc var path: String { disk.path }

    @objc var notes: String { disk.notes }

    /// The size the guest sees, in gigabytes of 10^9 bytes — the unit the app
    /// states disk sizes in — or `missing value` when the image can't be read.
    @objc var capacity: NSNumber? { Self.gigabytes(disk.capacityBytes) }

    /// What the image takes on its volume, in the unit ``capacity`` is.
    @objc var usedSpace: NSNumber? { Self.gigabytes(disk.usedBytes) }

    private static func gigabytes(_ bytes: UInt64?) -> NSNumber? {
        bytes.map { NSNumber(value: Double($0) / 1_000_000_000) }
    }

    // MARK: - Specifier

    /// How a script names this disk back — `storage disk id "…"` of
    /// `virtual machine id "…"`, which no rename or reorder invalidates.
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let virtualMachine = NSScriptClassDescription(for: VMScriptObject.self) else {
            #log(Self.logger, .fault, "VMScriptObject has no scripting class description")
            assertionFailure("VMScriptObject has no scripting class description")
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: virtualMachine,
            containerSpecifier: VMScriptObject.specifier(for: vm),
            key: VMScriptObject.storageDisksKey,
            uniqueID: disk.id.uuidString)
    }
}

// MARK: - Storage disk kind

/// The dictionary's `storage disk kind` enumeration, in Swift — the other half
/// of its enumerators in `Kernova.sdef`, which `KernovaScriptingDefinitionTests`
/// checks.
enum VMScriptStorageDiskKind: CaseIterable {
    case virtio
    case usbMassStorage

    /// The term `kind` is named by. Exhaustive, so a new bus has to be given a
    /// term before it compiles.
    init(_ kind: StorageDiskKind) {
        switch kind {
        case .virtio: self = .virtio
        case .usbMassStorage: self = .usbMassStorage
        }
    }

    /// The term for the kind a ``StorageDiskSummary`` names, `nil` for a name
    /// from no vocabulary this app writes.
    init?(wireName: String) {
        guard let kind = StorageDiskKind(rawValue: wireName) else { return nil }
        self.init(kind)
    }

    /// The term the dictionary names this kind with.
    var term: String {
        switch self {
        case .virtio: "virtio"
        case .usbMassStorage: "USB mass storage"
        }
    }

    /// The Apple event code the dictionary gives that term.
    var code: FourCharCode {
        switch self {
        case .virtio: FourCharCode(scriptingCode: "KdVi")
        case .usbMassStorage: FourCharCode(scriptingCode: "KdUs")
        }
    }
}
