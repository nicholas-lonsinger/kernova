import Cocoa
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// One snapshot, as a verb a script runs names it: the VM whose manifest lists
/// it, and its identifier there — which alone names nothing, since a clone
/// carries its source's snapshot identifiers.
struct VMSnapshotAddress: Hashable, Sendable {
    let vm: UUID
    let snapshot: UUID
}

/// One of a VM's snapshots, as the scripting dictionary's `snapshot`, each
/// ``SnapshotSummary`` field read by the key ``key(carrying:)`` names.
///
/// A copy of one listing, like ``VMScriptObject``: the VM lists its
/// snapshots afresh on every specifier evaluation. `name` and `notes` are its
/// writable properties, and setting one is the rename or note verb — the
/// gateway runs it and records a refusal on the command being answered. Its
/// sizes are measured when a script reads them
/// (``VMScriptingGateway/snapshotSize(of:)``).
@MainActor
@objc(VMSnapshotScriptObject)
package final class VMSnapshotScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMSnapshotScriptObject")

    /// The read every property but the sizes answers from.
    private let snapshot: SnapshotSummary
    /// Which snapshot it is.
    let address: VMSnapshotAddress
    /// Where a write runs and the sizes are read.
    private weak var gateway: VMScriptingGateway?

    init(_ snapshot: SnapshotSummary, of vm: UUID, gateway: VMScriptingGateway) {
        self.snapshot = snapshot
        address = VMSnapshotAddress(vm: vm, snapshot: snapshot.id)
        self.gateway = gateway
    }

    // MARK: - Properties

    @objc var uniqueID: String { snapshot.id.uuidString }

    @objc var name: String {
        get { snapshot.name }
        set { gateway?.renameSnapshot(address, to: newValue) }
    }

    @objc var notes: String {
        get { snapshot.notes }
        set { gateway?.setSnapshotNotes(address, to: newValue) }
    }

    /// The `snapshot kind` enumerator for what the capture holds, as the Apple
    /// event code the dictionary gives it.
    ///
    /// `missing value` for a kind from no vocabulary this app writes, which is
    /// a programming error rather than a snapshot a script can provoke.
    @objc var kind: NSNumber? {
        guard let kind = VMScriptSnapshotKind(wireName: snapshot.kind) else {
            Self.logger.log(
                .fault, "Snapshot kind '\(self.snapshot.kind, privacy: .public)' has no scripting term")
            assertionFailure("Snapshot kind '\(snapshot.kind)' has no scripting term")
            return nil
        }
        return NSNumber(value: kind.code)
    }

    @objc var creationDate: Date { snapshot.createdAt }

    @objc var current: Bool { snapshot.isCurrent }

    @objc var ephemeralBaseline: Bool { snapshot.isEphemeralBaseline }

    /// ``SnapshotSize/bytes``, in ``Foundation/NSNumber/init(gigabytesOf:)``'s
    /// unit.
    @objc var size: NSNumber? {
        gateway?.snapshotSize(of: address).map { NSNumber(gigabytesOf: $0.bytes) }
    }

    /// ``SnapshotSize/privateBytes``, in the unit ``size`` is.
    @objc var privateSize: NSNumber? {
        gateway?.snapshotSize(of: address)?.privateBytes.map { NSNumber(gigabytesOf: $0) }
    }

    /// The Cocoa key of the property the dictionary reads `field` by — the key
    /// `Kernova.sdef` gives that term, which `KernovaScriptingDefinitionTests`
    /// checks.
    static func key(carrying field: SnapshotSummary.Field) -> String {
        switch field {
        case .id: #keyPath(VMSnapshotScriptObject.uniqueID)
        case .name: #keyPath(VMSnapshotScriptObject.name)
        case .notes: #keyPath(VMSnapshotScriptObject.notes)
        case .kind: #keyPath(VMSnapshotScriptObject.kind)
        case .createdAt: #keyPath(VMSnapshotScriptObject.creationDate)
        case .isCurrent: #keyPath(VMSnapshotScriptObject.current)
        case .isEphemeralBaseline: #keyPath(VMSnapshotScriptObject.ephemeralBaseline)
        }
    }

    // MARK: - Specifier

    /// How a script names this snapshot back — `snapshot id "…"` of
    /// `virtual machine id "…"`, which no rename, reorder or new snapshot
    /// invalidates.
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        Self.specifier(for: address)
    }

    /// `snapshot id "…"` of `virtual machine id "…"`, for the snapshot
    /// `address` names.
    nonisolated static func specifier(for address: VMSnapshotAddress) -> NSScriptObjectSpecifier? {
        guard let virtualMachine = NSScriptClassDescription(for: VMScriptObject.self) else {
            Self.logger.log(.fault, "VMScriptObject has no scripting class description")
            assertionFailure("VMScriptObject has no scripting class description")
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: virtualMachine,
            containerSpecifier: VMScriptObject.specifier(for: address.vm),
            key: VMScriptObject.snapshotsKey,
            uniqueID: address.snapshot.uuidString)
    }
}

// MARK: - Snapshot kind

/// The dictionary's `snapshot kind` enumeration, in Swift — the other half of
/// its enumerators in `Kernova.sdef`, which `KernovaScriptingDefinitionTests`
/// checks.
enum VMScriptSnapshotKind: CaseIterable {
    case warm
    case cold

    /// The term `kind` is named by. Exhaustive, so a new kind has to be given a
    /// term before it compiles.
    init(_ kind: VMSnapshotKind) {
        switch kind {
        case .warm: self = .warm
        case .cold: self = .cold
        }
    }

    /// The term for the kind a ``SnapshotSummary`` names, `nil` for a name from
    /// no vocabulary this app writes.
    init?(wireName: String) {
        guard let kind = VMSnapshotKind(rawValue: wireName) else { return nil }
        self.init(kind)
    }

    /// The Apple event code the dictionary gives this case's term.
    var code: FourCharCode {
        switch self {
        case .warm: FourCharCode(scriptingCode: "KkWa")
        case .cold: FourCharCode(scriptingCode: "KkCo")
        }
    }
}
