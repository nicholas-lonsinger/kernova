import Cocoa
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// One of the library's smart groups or folders, as the scripting
/// dictionary's `smart group` or `folder`, each ``GroupSummary`` field read
/// by the key ``key(carrying:)`` names.
///
/// A copy of one read, like ``VMNetworkScriptObject``: the application
/// rebuilds the list on every specifier evaluation. Every property is read
/// only. Its kind is the class it is — ``VMSmartGroupScriptObject`` or
/// ``VMFolderScriptObject`` — since Cocoa answers an object's class from its
/// own implementation class.
@MainActor
package class VMGroupScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMGroupScriptObject")

    /// The read every property answers from.
    private let group: GroupSummary
    /// The VMs in it, as the dictionary's `virtual machine`.
    private let members: [VMScriptObject]
    /// Where a member's name resolves.
    private weak var gateway: VMScriptingGateway?

    fileprivate init(_ group: GroupSummary, members: [VMScriptObject], gateway: VMScriptingGateway) {
        self.group = group
        self.members = members
        self.gateway = gateway
    }

    /// The object of `group`'s kind.
    static func make(_ group: GroupSummary, members: [VMScriptObject], gateway: VMScriptingGateway)
        -> VMGroupScriptObject
    {
        switch group.kind {
        case .smartGroup: VMSmartGroupScriptObject(group, members: members, gateway: gateway)
        case .folder: VMFolderScriptObject(group, members: members, gateway: gateway)
        }
    }

    /// How a command addresses the group this stands for: by identifier,
    /// which no rename changes.
    nonisolated var reference: VMGroupReference { VMGroupReference(group.kind, named: group.id.uuidString) }

    // MARK: - Properties

    @objc var uniqueID: String { group.id.uuidString }

    @objc var name: String { group.name }

    @objc var virtualMachines: [VMScriptObject] { members }

    /// The named-element accessor Cocoa resolves `virtual machine "…" of
    /// folder …` through, among ``virtualMachines`` — see
    /// ``VMScriptingGateway/virtualMachine(named:among:placement:)``.
    @objc(valueInVirtualMachinesWithName:)
    func valueInVirtualMachines(withName name: String) -> VMScriptObject? {
        gateway?.virtualMachine(
            named: name, among: members, placement: "in the \(group.kind.noun) \u{201C}\(group.name)\u{201D}")
    }

    /// The Cocoa key of the property or element the dictionary reads `field`
    /// by — the key `Kernova.sdef` gives that term, which
    /// `KernovaScriptingDefinitionTests` checks — or `nil` for a field no term
    /// reads.
    static func key(carrying field: GroupSummary.Field) -> String? {
        switch field {
        case .id: #keyPath(VMGroupScriptObject.uniqueID)
        case .name: #keyPath(VMGroupScriptObject.name)
        // The class a group is: `class of` answers smart group or folder.
        case .kind: nil
        case .members: #keyPath(VMGroupScriptObject.virtualMachines)
        }
    }

    // MARK: - Elements

    /// Refuses `make new virtual machine at` a group: a script puts no VM in
    /// one.
    ///
    /// Cocoa's own answer allocates the element's class with `init()`, which
    /// ``VMScriptObject`` does not have — so it would trap.
    package nonisolated override func newScriptingObject(
        of objectClass: AnyClass, forValueForKey key: String, withContentsValue contentsValue: Any?,
        properties: [String: Any]
    ) -> Any? {
        MainActor.assumeIsolated {
            gateway?.refuseToMake(VMScriptingGateway.cannotMakeVirtualMachine)
        }
        return nil
    }

    // MARK: - Specifier

    /// How a script names this group back — `smart group id "…"` or `folder
    /// id "…"` of the application, which no rename invalidates.
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else {
            Self.logger.log(.fault, "NSApplication has no scripting class description")
            assertionFailure("NSApplication has no scripting class description")
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: application,
            containerSpecifier: nil,
            key: VMScriptingRoot.groupsKey(of: group.kind),
            uniqueID: group.id.uuidString)
    }
}

/// A smart group, as the dictionary's `smart group`.
@objc(VMSmartGroupScriptObject)
package final class VMSmartGroupScriptObject: VMGroupScriptObject {}

/// A folder, as the dictionary's `folder`.
@objc(VMFolderScriptObject)
package final class VMFolderScriptObject: VMGroupScriptObject {}
