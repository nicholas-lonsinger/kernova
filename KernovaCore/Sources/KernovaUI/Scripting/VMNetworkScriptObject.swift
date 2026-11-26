import Cocoa
import CoreServices
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// One named network as the scripting dictionary's `network`, each
/// ``NetworkSummary`` field read by the key ``key(carrying:)`` names.
///
/// A copy of one read, like ``VMScriptObject``: the container rebuilds the
/// list on every specifier evaluation. `name` is its one writable property,
/// and setting it is the rename verb — the gateway runs it and records a
/// refusal on the command being answered.
@MainActor
@objc(VMNetworkScriptObject)
package final class VMNetworkScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMNetworkScriptObject")

    /// The read every property answers from.
    private let network: NetworkSummary
    /// The VMs on it, as the dictionary's `virtual machine`.
    private let members: [VMScriptObject]
    /// Where a rename runs.
    private weak var gateway: VMScriptingGateway?

    init(_ network: NetworkSummary, members: [VMScriptObject], gateway: VMScriptingGateway) {
        self.network = network
        self.members = members
        self.gateway = gateway
    }

    // MARK: - Properties

    @objc var uniqueID: String { network.id.uuidString }

    @objc var name: String {
        get { network.name }
        set { gateway?.renameNetwork(network.id, to: newValue) }
    }

    /// The `network kind` enumerator for the network's kind, as the Apple event
    /// code the dictionary gives it.
    @objc var kind: NSNumber { NSNumber(value: VMScriptNetworkKind(network.kind).code) }

    @objc var virtualMachines: [VMScriptObject] { members }

    /// The named-element accessor Cocoa resolves `virtual machine "…" of
    /// network …` through — see ``VMScriptingGateway/virtualMachine(named:in:)``.
    @objc(valueInVirtualMachinesWithName:)
    func valueInVirtualMachines(withName name: String) -> VMScriptObject? {
        gateway?.virtualMachine(named: name, in: VMNameScope(network))
    }

    /// The Cocoa key of the property or element the dictionary reads `field`
    /// by — the key `Kernova.sdef` gives that term, which
    /// `KernovaScriptingDefinitionTests` checks.
    static func key(carrying field: NetworkSummary.Field) -> String {
        switch field {
        case .id: #keyPath(VMNetworkScriptObject.uniqueID)
        case .name: #keyPath(VMNetworkScriptObject.name)
        case .kind: #keyPath(VMNetworkScriptObject.kind)
        case .members: #keyPath(VMNetworkScriptObject.virtualMachines)
        }
    }

    // MARK: - Elements

    /// Refuses `make new virtual machine at` a network: a VM joins one through
    /// its own `network.membership` key.
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

    /// How a script names this network back — `network id "…"` of the
    /// application, which no rename invalidates.
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else {
            Self.logger.log(.fault, "NSApplication has no scripting class description")
            assertionFailure("NSApplication has no scripting class description")
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: application,
            containerSpecifier: nil,
            key: VMScriptingRoot.networksKey,
            uniqueID: network.id.uuidString)
    }
}

// MARK: - Network kind

/// The dictionary's `network kind` enumeration, in Swift — the other half of
/// its enumerators in `Kernova.sdef`, which `KernovaScriptingDefinitionTests`
/// checks.
enum VMScriptNetworkKind: CaseIterable {
    case nat
    case hostOnly

    /// The term `kind` is named by. Exhaustive, so a new kind has to be given
    /// a term before it compiles.
    init(_ kind: NetworkKind) {
        switch kind {
        case .nat: self = .nat
        case .hostOnly: self = .hostOnly
        }
    }

    /// The kind an Apple event naming `code` asked for, `nil` for a code from
    /// no vocabulary this app writes.
    init?(code: FourCharCode) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    /// The Apple event code the dictionary gives this case's term.
    var code: FourCharCode {
        switch self {
        case .nat: FourCharCode(scriptingCode: "KnSh")
        case .hostOnly: FourCharCode(scriptingCode: "KnHo")
        }
    }

    /// The kind this term names.
    var kind: NetworkKind {
        switch self {
        case .nat: .nat
        case .hostOnly: .hostOnly
        }
    }
}
