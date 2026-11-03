/// What one install scope puts in its service manager's hands: the files the manager runs the agent from —
/// systemd units, launchd property lists — and the commands that load, start and unload them. ``InstallPlan``
/// places them around the agent's own root, which the core lays out.
///
/// Every file runs the agent through ``InstallRoot/current``, and the rollback check through
/// ``InstallRoot/rollback``, so an update that switches slots rewrites none of them.
public protocol ServiceDefinitions {
    /// What an install writes outside the agent's root, in order, each directory before what it holds. An
    /// uninstall removes every file among them, and a refresh rewrites them all.
    var writes: [InstallPlan.Write] { get }
    /// Run before an install writes or removes anything. They stop the rollback check, so no check judges a
    /// half-written root or the fresh install.
    var beforeInstall: [InstallPlan.Command] { get }
    /// Run once an install has written everything. They start the rollback check and the peer, restarting a
    /// peer already running so it runs the payload just landed.
    var afterInstall: [InstallPlan.Command] { get }
    /// Run before an uninstall removes anything. They stop the peer and the rollback check.
    var beforeUninstall: [InstallPlan.Command] { get }
    /// Run once an uninstall has removed everything.
    var afterUninstall: [InstallPlan.Command] { get }
    /// Run once a refresh has rewritten ``writes``, so the manager reads them again.
    var afterRefresh: [InstallPlan.Command] { get }
}

extension ServiceDefinitions {
    /// The files among ``writes``: what an uninstall removes.
    public var files: [String] {
        writes.compactMap { write in
            if case .file(let path, _, _) = write { path } else { nil }
        }
    }
}

/// The service manager running one install scope's peer, as the rollback check reaches it.
///
/// The manager restarts the peer through ``InstallRoot/current`` when its process is killed, and the check's
/// revert rests on it: killing the new version is what starts the previous one.
public protocol ServiceManager {
    /// The peer's running process; 0 when it has none, as while it waits to restart.
    func peerProcessID() throws -> UInt32
}
