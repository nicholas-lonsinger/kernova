#if canImport(Darwin) || os(Linux)
import KernovaAgentCore
import KernovaLogging

/// The agent's `rollback-check`: one run of the check that reverts an update the new version does not
/// confirm (spec §8.4). The service manager runs it every `UpdateRollbackPolicy.checkIntervalSeconds` from
/// ``InstallRoot/rollback``, the previous slot's agent, so it never runs inside the version it judges.
///
/// It counts its own runs rather than reading a clock (decision M2): a guest powered off, or a VM paused,
/// mid-switch spends no runs, so no wall-clock leap reverts a good update.
public struct RollbackCheck {
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
    /// The manager running the peer it judges.
    let serviceManager: any ServiceManager
    /// Sends SIGKILL to a process.
    let kill: (UInt32) -> Void

    /// The check of the install at `root`, whose peer `serviceManager` runs and `kill` kills.
    public init(root: SlotRoot, serviceManager: any ServiceManager, kill: @escaping (UInt32) -> Void) {
        self.root = root
        self.serviceManager = serviceManager
        self.kill = kill
    }

    /// Runs the check once. At the ``runsToRevert``th run it takes the switch from the new version, points
    /// `current` back at the slot the switch left, and kills the peer's process, which shares this one's
    /// uid; the service manager then starts the previous version through `current`, and that version records
    /// the reverted payload as rejected as it starts.
    func run() throws -> Outcome {
        guard root.exists(InstallRoot.switchPendingName) else { return .nothingPending }
        let state = try root.readState()
        guard let pending = state.pendingSwitch else {
            try root.remove(InstallRoot.switchPendingName)
            return .clearedStaleMarker
        }
        guard let runs = try root.countRollbackRun() else { return .confirmedMeanwhile }
        guard runs >= Self.runsToRevert else { return .counted(runs: runs) }
        guard try root.claimRollback() else { return .confirmedMeanwhile }
        try root.point(InstallRoot.currentLinkName, at: pending.from)
        let pid = try serviceManager.peerProcessID()
        guard pid > 0 else { return .reverted(killed: nil) }
        kill(pid)
        return .reverted(killed: pid)
    }

    /// Runs the check once and logs what it did, or why it failed: false when it failed.
    public func run(logger: KernovaLogger) -> Bool {
        let outcome: Outcome
        do {
            outcome = try run()
        } catch {
            logger.log(.error, "The rollback check failed: \(String(describing: error), privacy: .public)")
            return false
        }
        switch outcome {
        case .nothingPending:
            break
        case .clearedStaleMarker:
            logger.log(.notice, "Removed a switch-pending marker that named no update")
        case .counted(let runs):
            logger.log(.notice, "The update is unconfirmed after \(runs) of \(Self.runsToRevert) rollback checks")
        case .confirmedMeanwhile:
            logger.log(.notice, "The update was confirmed as the rollback check ran")
        case .reverted(let killed):
            logger.log(
                .error,
                """
                The update was never confirmed: rolled back to the previous version, killing process \
                \(killed.map(String.init) ?? "none", privacy: .public)
                """)
        }
        return true
    }
}
#endif
