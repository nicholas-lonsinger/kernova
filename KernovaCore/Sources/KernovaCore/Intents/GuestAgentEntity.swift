import AppIntents
import Foundation
import KernovaCommandModel

/// One guest agent a VM's session reaches, as a Shortcut reads it.
///
/// Transient because no intent takes an agent as a parameter: an agent only
/// ever leaves a ``VMEntity`` as a value, so there is no identifier to
/// re-resolve.
struct GuestAgentEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Guest Agent")

    /// ``VMAgentLine/role``, as its wire name.
    @Property(title: "Role")
    var role: String

    @Property(title: "User")
    var user: String?

    /// ``VMAgentLine/status``.
    @Property(title: "Status")
    var status: String

    @Property(title: "Version")
    var version: String

    init() {}

    /// The entity `line` describes, accounting for each ``VMAgentLine/Field``.
    init(_ line: VMAgentLine) {
        for field in VMAgentLine.Field.allCases {
            switch field {
            case .role: role = line.role.rawValue
            case .user: user = line.user
            case .status: status = line.status
            case .version: version = line.version
            }
        }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(VMAgentRole(rawValue: role)?.title(user: user) ?? role)",
            subtitle: "\(AgentStatus.Kind(rawValue: status)?.title ?? status)")
    }
}
