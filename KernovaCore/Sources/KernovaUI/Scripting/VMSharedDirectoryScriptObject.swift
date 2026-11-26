import Cocoa
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// One shared directory, as a verb a script runs names it: the VM that shares
/// it, and the folder's path as that VM carries it, which a VM shares at most
/// once.
struct VMSharedDirectoryAddress: Sendable {
    let vm: UUID
    let path: String
}

/// One folder a VM shares with its guest, as the scripting dictionary's
/// `shared directory`, each ``SharedDirectorySummary`` field read by the key
/// ``key(carrying:)`` names.
///
/// A copy of one read, like ``VMScriptObject``: the VM lists its shares afresh
/// on every specifier evaluation. Every property is read only.
@MainActor
@objc(VMSharedDirectoryScriptObject)
package final class VMSharedDirectoryScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMSharedDirectoryScriptObject")

    /// The read every property answers from.
    private let share: SharedDirectorySummary
    /// Which share it is.
    let address: VMSharedDirectoryAddress

    init(_ share: SharedDirectorySummary, of vm: UUID) {
        self.share = share
        address = VMSharedDirectoryAddress(vm: vm, path: share.path)
    }

    // MARK: - Properties

    @objc var name: String { share.name }

    @objc var path: String { share.path }

    @objc var readOnly: Bool { share.readOnly }

    /// The Cocoa key of the property the dictionary reads `field` by — the key
    /// `Kernova.sdef` gives that term, which `KernovaScriptingDefinitionTests`
    /// checks.
    static func key(carrying field: SharedDirectorySummary.Field) -> String {
        switch field {
        case .name: #keyPath(VMSharedDirectoryScriptObject.name)
        case .path: #keyPath(VMSharedDirectoryScriptObject.path)
        case .readOnly: #keyPath(VMSharedDirectoryScriptObject.readOnly)
        }
    }

    // MARK: - Specifier

    /// How a script names this share back — `shared directory "<path>"` of
    /// `virtual machine id "…"`: the path names one share of a VM
    /// (``VMScriptingGateway/sharedDirectory(named:of:)``).
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        Self.specifier(for: address)
    }

    /// `shared directory "<path>"` of `virtual machine id "…"`, for the share
    /// `address` names.
    nonisolated static func specifier(for address: VMSharedDirectoryAddress) -> NSScriptObjectSpecifier? {
        guard let virtualMachine = NSScriptClassDescription(for: VMScriptObject.self) else {
            Self.logger.log(.fault, "VMScriptObject has no scripting class description")
            assertionFailure("VMScriptObject has no scripting class description")
            return nil
        }
        return NSNameSpecifier(
            containerClassDescription: virtualMachine,
            containerSpecifier: VMScriptObject.specifier(for: address.vm),
            key: VMScriptObject.sharedDirectoriesKey,
            name: address.path)
    }
}
