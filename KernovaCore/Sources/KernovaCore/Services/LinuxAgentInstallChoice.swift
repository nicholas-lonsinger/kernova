import KernovaCommandModel

/// What an install from the Linux agent's disk installs: the session agent, the system service, or both —
/// the agents the disk then waits for before it ejects.
package enum LinuxAgentInstallChoice: CaseIterable, Sendable {
    case both
    case sessionAgent
    case systemService

    /// The choice that installs exactly `scopes`; `nil` for none.
    package init?(installing scopes: Set<GuestAgentScope>) {
        switch (scopes.contains(.login), scopes.contains(.system)) {
        case (true, true): self = .both
        case (true, false): self = .sessionAgent
        case (false, true): self = .systemService
        case (false, false): return nil
        }
    }

    /// The choice an install starts on: the agents the VM has run before, which an update or a reinstall
    /// puts back, and both on a VM that has run neither.
    package init(seen: Set<GuestAgentScope>) {
        self = Self(installing: seen) ?? .both
    }

    /// The agents it installs.
    package var scopes: Set<GuestAgentScope> {
        switch self {
        case .both: [.login, .system]
        case .sessionAgent: [.login]
        case .systemService: [.system]
        }
    }

    /// The choice as the user reads it, in the terms the agent status rows use.
    package var title: String {
        switch self {
        case .both: "Session agent and system service"
        case .sessionAgent: "Session agent"
        case .systemService: "System service"
        }
    }
}
