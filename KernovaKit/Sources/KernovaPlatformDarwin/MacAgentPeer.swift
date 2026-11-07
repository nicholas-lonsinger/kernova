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
import KernovaWire

/// This process's v2 peer: its claim, its connection to the host through `PeerAgentRuntime`, its power adapter
/// and update installer, and the watch on its install's `current` link.
///
/// A peer relaunches by exiting 75 (EX_TEMPFAIL), which launchd restarts through `current` (`KeepAlive`
/// `SuccessfulExit` false): after the update it installed itself, and whenever `current` moves away from the
/// slot it runs from — another peer's switch, a fresh install, or the rollback check's revert — so each process
/// runs the slot its install runs. It exits 0, staying stopped, once `current` is gone with its install.
public final class MacAgentPeer: Sendable {
    /// The status a peer exits with to relaunch.
    public static let relaunchStatus: Int32 = 75

    /// The lander of the macOS agent's payloads: the app bundle, an update's checked against the running agent's
    /// launch requirement and then self-tested through its executable.
    public static let lander = ContainerTreeLander(
        itemName: MacInstallLayout.appName, selfTestExecutable: MacInstallLayout.executable,
        system: ContainerTreeLander.System(launchRefusal: { LaunchRequirement.refusal(ofBundleAt: $0) }))

    private static let logger = KernovaLogger(subsystem: "app.kernova.macosagent", category: "Peer")

    /// What it claims.
    public let claim: PeerClaim
    private let runtime: PeerAgentRuntime
    private let power: MacPowerAdapter
    private let watcher: Locked<SlotLinkWatcher?> = Locked(nil)
    private let exiting = Locked(false)
    /// Where the watch on `current` and the update installer run: one serial queue, so the peer's own switch
    /// reports its payload installed before the watch sees `current` move and closes the connection.
    private let queue: DispatchQueue

    /// The peer of `role`, labelled `label`, its records forwarded through `logs`. It dials once
    /// `setPeerState(_:)` gives it a session to serve, or at once with `state`. A session peer lands what the
    /// host drops in the user's Downloads folder and hands each drop's items to `revealDrop`, and serves the
    /// other item features `owners` builds owners for, each calling into the connection through the calls it
    /// is handed. Each change of ``hostConnection`` reaches `hostConnectionChanged`, on the runtime's queue.
    /// It reaches the host through `dialer`.
    public init(
        role: PeerRole, label: String, logs: LogForwarding, state: PeerSessionState?, dialer: any TransportDialer,
        hostConnectionChanged: @escaping @Sendable (HostConnectionState) -> Void = { _ in },
        revealDrop: @escaping @Sendable ([URL]) -> Void = { _ in },
        owners: (PeerItemCalls) -> ItemFeatureOwners = { _ in ItemFeatureOwners() }
    ) {
        claim = DarwinIdentity.current(role: role, versionLabel: label)
        let running = DarwinIdentity.runningSlot()
        let peer = Locked<MacAgentPeer?>(nil)
        let queue = DispatchQueue(label: "app.kernova.macosagent.peer")
        self.queue = queue
        let (adapter, installer) = Self.updateInstaller(for: claim, running: running, queue: queue, peer: peer)
        let sink = ItemSinkAdapter(fileSystem: POSIXTreeFileSystem())
        let calls = PeerItemCalls(sink: sink)
        let power = role == .systemPeer ? MacPowerAdapter.systemPeer() : MacPowerAdapter.sessionPeer()
        if let state { power.consoleChanged(state.console) }
        self.power = power
        // A system peer serves no items: `ItemFeatureAvailability.advertised(by:)` says why.
        let built = role == .sessionPeer ? owners(calls) : ItemFeatureOwners()
        let drop = role == .sessionPeer ? Self.dropReceiver(sink: sink, reveal: revealDrop) : nil
        let itemLogger = KernovaLogger(subsystem: "app.kernova.macosagent", category: "ItemSource")
        let itemRouter = ItemFeatureRouter<Void>(
            clipboard: built.clipboard, drop: drop?.owner, drag: built.drag, logger: itemLogger)
        let items =
            role == .sessionPeer
            ? ItemAdapters(
                source: ItemSourceAdapter(fileSystem: POSIXTreeFileSystem(), logger: itemLogger) {
                    itemRouter.content($0, $1, $2, $3)
                },
                sink: sink, features: itemRouter.features)
            : nil
        runtime = PeerAgentRuntime(
            claim: claim, state: state,
            registry: PeerFeatureRegistry(power: power, logs: logs, update: adapter, items: items),
            dialer: dialer, scheduler: SystemScheduler(), logger: Self.logger,
            handlers: PeerAgentRuntime.Handlers(
                event: { event in
                    // A PolicyUpdate follows the host's Hello: this version is connected, so it keeps itself.
                    if case .policyReceived = event { installer?.confirm() }
                    itemRouter.deliver(event)
                },
                hostConnectionChanged: hostConnectionChanged,
                stop: { reason in
                    Self.logger.log(.notice, "The peer stops for good: \(String(describing: reason), privacy: .public)")
                    Darwin.exit(0)
                }))
        calls.bind(runtime)
        peer.withLock { $0 = self }
        drop?.attach(runtime)
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

    /// ``PeerAgentRuntime/hostConnection``.
    public var hostConnection: HostConnectionState {
        runtime.hostConnection
    }

    /// Starts the adapters and dials.
    public func start() {
        runtime.start()
    }

    /// The session's state changed.
    public func setPeerState(_ state: PeerSessionState?) {
        power.consoleChanged(state?.console ?? .unknown)
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

    /// DROP's receiver: it lands each drop in the user's Downloads folder, which the agent, unsandboxed, reads
    /// as the real one, and hands what landed to `reveal`.
    private static func dropReceiver(
        sink: ItemSinkAdapter<POSIXTreeFileSystem>, reveal: @escaping @Sendable ([URL]) -> Void
    ) -> DropReceiver<POSIXTreeFileSystem> {
        let downloads =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        return DropReceiver(
            directory: downloads.path, sink: sink,
            logger: KernovaLogger(subsystem: "app.kernova.macosagent", category: "Drop")
        ) { names in
            reveal(
                names.map { name in
                    downloads.appendingPathComponent(String(decoding: name, as: UTF8.self))
                })
        }
    }

    /// The update adapter `claim` registers, and the installer behind it when it has one.
    ///
    /// The installer of the install this executable runs from serves the peer that pulls and switches: the
    /// session peer of a "Just for me" install, the system peer of a "For everyone" one. A "For everyone"
    /// install's session peers advertise UPDATE absent, `NOT_SERVED_BY_ROLE`: the host offers them nothing, and
    /// they follow the system peer's switch through `current`. A development build run from no install has none.
    private static func updateInstaller(
        for claim: PeerClaim, running: (root: String, slot: String)?, queue: DispatchQueue,
        peer: Locked<MacAgentPeer?>
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
            root: root, runningSlot: running.slot, lander: lander, logger: logger, queue: queue,
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

    /// Rewrites the user scope's property lists that differ from what this binary writes, logging each one it
    /// wrote; launchd reads them at the next login.
    private static func refreshUserJobs(root: String) {
        let suffix = "/" + MacInstallLayout.userRootBelowHome
        guard root.hasSuffix(suffix) else {
            return logger.log(.error, "Cannot rewrite the user's jobs: the install is not in a home's Library")
        }
        let layout = MacInstallLayout.user(home: String(root.dropLast(suffix.count)), userID: getuid())
        let installer = Installer(
            stagingRoot: "", runsCommands: true, payloadSource: nil, lander: lander, versionLabel: "", account: nil)
        do throws(Installer.Failure) {
            let written = try installer.run(.refreshJobs(layout))
            if !written.isEmpty {
                logger.log(
                    .notice,
                    "Rewrote the user's jobs for this version: \(written.joined(separator: ", "), privacy: .public)")
            }
        } catch {
            logger.log(.error, "Cannot rewrite the user's jobs: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The owners of the item features a session peer serves besides DROP, which the peer owns itself; a feature
/// with none is advertised absent.
public struct ItemFeatureOwners: Sendable {
    /// CLIPBOARD's owner.
    public var clipboard: ItemFeatureOwner<Void>?
    /// DRAG's owner.
    public var drag: DragFeatureOwner<Void>?

    /// Owners for the features given one.
    public init(clipboard: ItemFeatureOwner<Void>? = nil, drag: DragFeatureOwner<Void>? = nil) {
        self.clipboard = clipboard
        self.drag = drag
    }
}

/// A session peer's item calls into its connection to the host, for the owners of its item features: built
/// before the runtime they reach, which the peer binds before it starts, so nothing calls through them unbound.
public final class PeerItemCalls: Sendable {
    private let runtime = Locked<PeerAgentRuntime?>(nil)
    private let sink: ItemSinkAdapter<POSIXTreeFileSystem>

    init(sink: ItemSinkAdapter<POSIXTreeFileSystem>) {
        self.sink = sink
    }

    func bind(_ runtime: PeerAgentRuntime) {
        self.runtime.withLock { $0 = runtime }
    }

    private var bound: PeerAgentRuntime? {
        let runtime = runtime.withLock { $0 }
        if runtime == nil { assertionFailure("an item call before the peer bound its runtime") }
        return runtime
    }

    /// ``PeerAgentRuntime/offerItems(_:feature:_:)``.
    public func offerItems(
        _ offer: ItemOffer, feature: FeatureID, _ completion: @escaping @Sendable (WireError?) -> Void
    ) {
        guard let runtime = bound else { return completion(WireError(.internal, debugDetail: "no runtime")) }
        runtime.offerItems(offer, feature: feature, completion)
    }

    /// ``PeerAgentRuntime/withdrawOffer(_:code:)``.
    public func withdrawOffer(_ token: Data, code: ErrorCode = .cancelled) {
        bound?.withdrawOffer(token, code: code)
    }

    /// ``PeerAgentRuntime/releaseOffer(_:)``.
    public func releaseOffer(_ token: Data) {
        bound?.releaseOffer(token)
    }

    /// ``PeerAgentRuntime/refuseOffer(_:_:)``.
    public func refuseOffer(_ token: Data, _ error: WireError) {
        bound?.refuseOffer(token, error)
    }

    /// ``PeerAgentRuntime/pullItem(_:_:)``.
    public func pullItem(
        _ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
    ) {
        guard let runtime = bound else {
            return completion(.failure(WireError(.internal, debugDetail: "no runtime")))
        }
        runtime.pullItem(order, completion)
    }

    /// ``PeerAgentRuntime/cancelPull(_:)``.
    public func cancelPull(_ id: ItemPullID) {
        bound?.cancelPull(id)
    }

    /// ``PeerAgentRuntime/readItem(_:item:_:)``.
    public func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
        guard let runtime = bound else { return completion(nil) }
        runtime.readItem(token, item: item, completion)
    }

    /// ``PeerAgentRuntime/answerDragTake(_:_:)``.
    public func answerDragTake(_ id: DragTakeID, _ answer: DragTakeAnswer) {
        bound?.answerDragTake(id, answer)
    }

    /// The pull the peer's item sink lands, as
    /// ``ItemSinkAdapter/order(token:item:representation:byteCeiling:landing:budget:)`` builds it.
    public func order(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
        budget: ByteBudget?
    ) throws(WireError) -> ItemPullOrder {
        try sink.order(
            token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing,
            budget: budget)
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
