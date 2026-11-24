import Cocoa
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// One guest agent a VM's session reaches, as the scripting dictionary's
/// `guest agent`, each ``VMAgentLine`` field read by the key
/// ``key(carrying:)`` names.
///
/// A snapshot of one read, like ``VMScriptObject``: the VM rebuilds its list
/// on every specifier evaluation. Every property is read only.
@MainActor
@objc(VMGuestAgentScriptObject)
package final class VMGuestAgentScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMGuestAgentScriptObject")

    /// The read every property answers from.
    private let agent: VMAgentLine
    /// Where the agent sits in its VM's ``VMInfo/agents``.
    private let index: Int
    /// The VM whose session reaches it.
    private let vm: UUID

    init(_ agent: VMAgentLine, at index: Int, of vm: UUID) {
        self.agent = agent
        self.index = index
        self.vm = vm
    }

    // MARK: - Properties

    /// ``VMAgentLine/role`` as its wire name.
    @objc var role: String { agent.role.rawValue }

    @objc var user: String? { agent.user }

    @objc var status: String { agent.status }

    @objc var version: String { agent.version }

    /// The Cocoa key of the property the dictionary reads `field` by — the key
    /// `Kernova.sdef` gives that term, which `KernovaScriptingDefinitionTests`
    /// checks.
    static func key(carrying field: VMAgentLine.Field) -> String {
        switch field {
        case .role: #keyPath(VMGuestAgentScriptObject.role)
        case .user: #keyPath(VMGuestAgentScriptObject.user)
        case .status: #keyPath(VMGuestAgentScriptObject.status)
        case .version: #keyPath(VMGuestAgentScriptObject.version)
        }
    }

    // MARK: - Specifier

    /// How a script names this agent back — `guest agent <n>` of
    /// `virtual machine id "…"`, which names whichever agent holds that place
    /// when the script uses it.
    ///
    /// No field of a line names one agent: the hub keys a connected session
    /// agent by its session (`PeerConflict.sameKey`), so one user can run two,
    /// and a line for an agent that didn't reconnect names no user.
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let virtualMachine = NSScriptClassDescription(for: VMScriptObject.self) else {
            Self.logger.log(.fault, "VMScriptObject has no scripting class description")
            assertionFailure("VMScriptObject has no scripting class description")
            return nil
        }
        return NSIndexSpecifier(
            containerClassDescription: virtualMachine,
            containerSpecifier: VMScriptObject.specifier(for: vm),
            key: VMScriptObject.guestAgentsKey,
            index: index)
    }
}
