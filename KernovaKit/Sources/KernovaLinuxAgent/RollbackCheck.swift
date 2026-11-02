#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaAgentCore

/// `kernova-agent rollback-check`: one run of the check that reverts an update the new version does not
/// confirm (spec §8.4). The rollback timer runs it every 30 s while `switch-pending` exists, from the
/// previous slot's binary, so it never runs inside the version it judges.
///
/// It counts its own runs rather than reading a clock (decision M2): a guest powered off, or a VM paused,
/// mid-switch spends no runs, so no wall-clock leap reverts a good update.
struct RollbackCheck {
    /// The run that reverts a switch still unconfirmed (`UpdateRollbackPolicy`).
    static let runsToRevert = UpdateRollbackPolicy.checksToRevert

    /// What a run did.
    enum Outcome: Equatable {
        /// No switch is pending.
        case nothingPending
        /// `switch-pending` named no switch the metadata records, and was removed.
        case clearedStaleMarker
        /// It counted this run, the `runs`th, against the pending switch.
        case counted(runs: Int)
        /// The new version confirmed the switch as the check was about to revert it.
        case confirmedMeanwhile
        /// It reverted the switch, and killed the unit's main process, `killed`, when there was one.
        case reverted(killed: UInt32?)
    }

    /// The install's root.
    let root: SlotRoot
    /// The peer's service's main process; 0 when it has none.
    let mainPID: () throws -> UInt32
    /// Sends SIGKILL to a process.
    let kill: (UInt32) -> Void

    /// Runs the check once. At the ``runsToRevert``th run it takes the switch from the new version, points
    /// `current` back at the slot the switch left, and kills the peer's process, which shares this one's
    /// uid; `Restart=on-failure` then starts the previous version through `current`, and that version
    /// records the reverted payload as rejected as it starts.
    func run() throws -> Outcome {
        guard root.exists(InstallLayout.switchPendingName) else { return .nothingPending }
        let state = try root.readState()
        guard let pending = state.pendingSwitch else {
            try root.remove(InstallLayout.switchPendingName)
            return .clearedStaleMarker
        }
        guard let runs = try root.countRollbackRun() else { return .confirmedMeanwhile }
        guard runs >= Self.runsToRevert else { return .counted(runs: runs) }
        guard try root.claimRollback() else { return .confirmedMeanwhile }
        try root.point(InstallLayout.currentLinkName, at: pending.from)
        let pid = try mainPID()
        guard pid > 0 else { return .reverted(killed: nil) }
        kill(pid)
        return .reverted(killed: pid)
    }
}
#endif
