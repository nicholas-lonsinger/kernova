import Foundation

/// Whether the sidebar's guest-agent install reminder shows for a VM: the
/// app-wide switch in Settings → Reminders, over each VM's own choice
/// (`VMHostState.agentInstallNudgeDismissed`).
///
/// While the reminder is off for every VM, each VM keeps its own choice — what
/// it returns to once the reminder is back on — and a write through
/// `agent.installReminder` that would change it is refused.
package struct AgentInstallReminder: Sendable, Equatable {
    /// Whether the reminder is turned off for every VM
    /// (`AppPreferences.agentInstallPromptDisabled`).
    package let isOffForAllVMs: Bool

    package init(isOffForAllVMs: Bool) {
        self.isOffForAllVMs = isOffForAllVMs
    }

    /// Whether a VM holding `hostState` shows the reminder while its agent is
    /// `.waiting`.
    package func shows(for hostState: VMHostState) -> Bool {
        !isOffForAllVMs && !hostState.agentInstallNudgeDismissed
    }
}
