#if os(macOS)
import Darwin
import Dispatch
import Foundation
import KernovaAgentCore
import KernovaAgentInstall
import KernovaAgentRuntime
import KernovaDigest
import KernovaFileTree
import KernovaItemTransfer
import KernovaLogging
import KernovaSynchronization

/// This process's v2 peer: its claim, its connection to the host through `PeerAgentRuntime`, its update
/// installer, and the watch on its install's `current` link.
///
/// A peer relaunches by exiting 75 (EX_TEMPFAIL), which launchd restarts through `current` (`KeepAlive`
/// `SuccessfulExit` false): after the update it installed itself, and whenever `current` moves away from the
/// slot it runs from — another peer's switch, a fresh install, or the rollback check's revert — so each process
/// runs the slot its install runs. It exits 0, staying stopped, once `current` is gone with its install.
public final class MacAgentPeer: Sendable {
    /// The status a peer exits with to relaunch.
    public static let relaunchStatus: Int32 = 75

    /// The lander of the macOS agent's payloads: the app bundle, its self-test run through its executable.
    public static let lander = ContainerTreeLander(
        itemName: MacInstallLayout.appName, selfTestExecutable: MacInstallLayout.executable)

    private static let logger = KernovaLogger(subsystem: "app.kernova.macosagent", category: "Peer")

    /// What it claims.
    public let claim: PeerClaim
    private let runtime: PeerAgentRuntime
    private let watcher: Locked<SlotLinkWatcher?> = Locked(nil)
    private let exiting = Locked(false)
    private let queue = DispatchQueue(label: "app.kernova.macosagent.peer")

    /// The peer of `role`, labelled `label`, its records forwarded through `logs`. It dials once
    /// `setPeerState(_:)` gives it a session to serve, or at once with `state`.
    public init(role: PeerRole, label: String, logs: LogForwarding, state: PeerSessionState?) {
        claim = DarwinIdentity.current(role: role, versionLabel: label)
        let running = DarwinIdentity.runningSlot()
        let peer = Locked<MacAgentPeer?>(nil)
        let (adapter, installer) = Self.updateInstaller(for: claim, running: running, peer: peer)
        // A system peer serves no items: `ItemFeatureAvailability.advertised(by:)` says why.
        let itemRouter = ItemFeatureRouter<Void>()
        let items =
            role == .sessionPeer
            ? ItemAdapters(
                source: ItemSourceAdapter(fileSystem: POSIXTreeFileSystem()) { itemRouter.content($0, $1, $2) },
                sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()), features: itemRouter.features)
            : nil
        runtime = PeerAgentRuntime(
            claim: claim, state: state, registry: PeerFeatureRegistry(logs: logs, update: adapter, items: items),
            dialer: DarwinVsockDialer(), scheduler: SystemScheduler(), logger: Self.logger,
            handlers: PeerAgentRuntime.Handlers(
                event: { event in
                    // A PolicyUpdate follows the host's Hello: this version is connected, so it keeps itself.
                    if event == .policyReceived { installer?.confirm() }
                    itemRouter.deliver(event)
                },
                stop: { reason in
                    Self.logger.log(.notice, "The peer stops for good: \(String(describing: reason), privacy: .public)")
                    Darwin.exit(0)
                }))
        peer.withLock { $0 = self }
        if let running, claim.scope != .unspecified {
            let watcher = SlotLinkWatcher(root: running.root, runningSlot: running.slot, queue: queue) {
                [self] change in
                switch change {
                case .moved:
                    Self.logger.log(.notice, "The install's current slot moved: the peer relaunches into it")
                    exit(status: Self.relaunchStatus)
                case .removed:
                    // Exiting 0 is what keeps launchd from restarting it (`KeepAlive` `SuccessfulExit` false).
                    Self.logger.log(.notice, "The install was removed: the peer stops")
                    exit(status: 0)
                }
            }
            self.watcher.withLock { $0 = watcher }
        }
        Self.logger.log(
            .notice,
            """
            The \(role == .systemPeer ? "system" : "session", privacy: .public) peer \(label, privacy: .public) \
            starts, scope \(String(describing: self.claim.scope), privacy: .public), payload \
            \(self.claim.payloadHash.isEmpty ? "none" : lowercaseHex(self.claim.payloadHash), privacy: .public)
            """)
    }

    /// Starts the adapters and dials.
    public func start() {
        runtime.start()
    }

    /// The session's state changed.
    public func setPeerState(_ state: PeerSessionState?) {
        runtime.setPeerState(state)
    }

    /// Closes the connection with `SHUTTING_DOWN`, then exits with `status`; once, whoever asks first.
    public func exit(status: Int32) {
        guard
            !exiting.withLock({ exiting in
                defer { exiting = true }; return exiting
            })
        else { return }
        watcher.withLock { $0 }?.cancel()
        runtime.close { Darwin.exit(status) }
    }

    /// The update adapter `claim` registers, and the installer behind it when it has one.
    ///
    /// The installer of the install this executable runs from serves the peer that pulls and switches: the
    /// session peer of a "Just for me" install, the system peer of a "For everyone" one. A "For everyone"
    /// install's session peers advertise UPDATE absent, `NOT_SERVED_BY_ROLE`: the host offers them nothing, and
    /// they follow the system peer's switch through `current`. A development build run from no install has none.
    private static func updateInstaller(
        for claim: PeerClaim, running: (root: String, slot: String)?, peer: Locked<MacAgentPeer?>
    ) -> (adapter: (any UpdateInstaller)?, installer: SlotUpdateInstaller?) {
        guard let running, claim.scope != .unspecified else { return (nil, nil) }
        guard claim.role == (claim.scope == .system ? .systemPeer : .sessionPeer) else {
            return (UpdateServedByAnotherRole(), nil)
        }
        let root: SlotRoot
        do throws(SlotRoot.Failure) {
            root = try SlotRoot(path: running.root)
        } catch {
            logger.log(.error, "Cannot open the install's root: \(String(describing: error), privacy: .public)")
            return (nil, nil)
        }
        let installer = SlotUpdateInstaller(
            root: root, runningSlot: running.slot, lander: lander, logger: logger,
            onSwitched: {
                logger.log(.notice, "The peer relaunches into the update")
                guard let peer = peer.withLock({ $0 }) else { Darwin.exit(relaunchStatus) }
                peer.exit(status: relaunchStatus)
            },
            onConfirmed: {
                if claim.scope == .user { refreshUserJobs(root: running.root) }
            })
        return (installer, installer)
    }

    /// Rewrites the user scope's property lists as this binary writes them; launchd reads them at the next login.
    private static func refreshUserJobs(root: String) {
        let suffix = "/" + MacInstallLayout.userRootBelowHome
        guard root.hasSuffix(suffix) else {
            return logger.log(.error, "Cannot rewrite the user's jobs: the install is not in a home's Library")
        }
        let layout = MacInstallLayout.user(home: String(root.dropLast(suffix.count)), userID: getuid())
        let installer = Installer(
            stagingRoot: "", runsCommands: true, payloadSource: nil, lander: lander, versionLabel: "", account: nil)
        do throws(Installer.Failure) {
            try installer.run(.refreshJobs(layout))
            logger.log(.notice, "Rewrote the user's jobs for this version")
        } catch {
            logger.log(.error, "Cannot rewrite the user's jobs: \(String(describing: error), privacy: .public)")
        }
    }
}

/// UPDATE as a "For everyone" install's session peer advertises it: another role pulls and switches its
/// install.
struct UpdateServedByAnotherRole: UpdateInstaller {
    func start(reporter: UpdateReporter) {
        reporter.report(.availability(.absent(.notServedByRole, debugDetail: "the system peer updates this install")))
    }
    func recordRejected(_ hash: Data) {}
    func clearRejected() {}
    func write(_ id: UpdatePullID, _ bytes: Data) {}
    func complete(_ id: UpdatePullID, _ manifest: UpdateManifestValue) {}
    func abort(_ id: UpdatePullID) {}
}
#endif
