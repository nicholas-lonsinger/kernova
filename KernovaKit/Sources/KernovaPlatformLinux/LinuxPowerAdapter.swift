#if os(Linux)
// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch does not.
@preconcurrency import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaDBus
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// A Linux peer's power: logind's `PowerOff` and `Reboot`, offered while polkit authorizes this agent for
/// them and the peer can see every app's unsaved work that the desktop's own logout would ask about.
///
/// logind's power-off asks no desktop to save, and only the gnome-session family lists its apps' unsaved
/// work where another process can read it (docs/research/2026-11-01-linux-desktop-unsaved-work-at-power-off.md).
/// So a session peer offers power only while a session manager serves `org.gnome.SessionManager`, and the
/// system peer, which cannot read a session bus, only while no desktop session runs.
///
/// Every D-Bus call runs on the adapter's own serial queue.
public final class LinuxPowerAdapter: PowerAdapter {
    /// The peer an adapter serves, with what that peer reads unsaved work from.
    public enum Peer: Sendable {
        /// The session peer, whose session's unsaved work the session manager lists.
        case session(GnomeSessionManager)
        /// The system peer.
        case system
    }

    /// How long a power call waits for logind: under the host's 10 s acceptance deadline, so a call
    /// logind never answers ends `.unconfirmed` while the host still waits on it.
    public static let defaultPowerCallTimeout: Duration = .seconds(8)

    /// The polkit actions logind checks for each power action, without the `-multiple-sessions` and
    /// `-ignore-inhibit` variants it checks when other users are logged in or a lock is held.
    private static let polkitActions: [(action: PowerAction, id: String)] = [
        (.shutdown, "org.freedesktop.login1.power-off"), (.restart, "org.freedesktop.login1.reboot"),
    ]

    private let peer: Peer
    private let logind: Logind
    private let polkit: PolkitAuthority
    private let powerCallTimeout: Duration
    private let logger = KernovaLogger(subsystem: "app.kernova.agent", category: "Power")
    private let queue = DispatchQueue(label: "app.kernova.agent.power")
    private let state = Locked(State())

    private struct State: Sendable {
        var reporter: PowerReporter?
        /// Session peer: whether its session holds the console.
        var onConsole = false
        /// The availability last reported; nil before the first report.
        var reported: Availability<PowerOffer>?
        var refreshQueued = false
        /// The changes followed: polkit's, and the session manager's owner or logind's session list.
        var subscriptions: [DBusSubscription] = []
        /// Requests performed whose terminal report nobody has yet claimed. Whoever removes one reports
        /// its end: `cancel(_:)` while nothing has been asked of logind, the request's own run otherwise.
        var unclaimed: Set<PowerRequestID> = []
    }

    /// The adapter for `peer`, calling logind and polkit over `systemBus`.
    public init(
        peer: Peer, systemBus: DBusBusConnection,
        powerCallTimeout: Duration = LinuxPowerAdapter.defaultPowerCallTimeout
    ) {
        self.peer = peer
        logind = Logind(connection: systemBus)
        polkit = PolkitAuthority(connection: systemBus)
        self.powerCallTimeout = powerCallTimeout
    }

    deinit {
        state.withLock { $0.subscriptions }.forEach { $0.cancel() }
    }

    /// Follows the changes that move the availability and reports the first one, on the adapter's queue.
    public func start(reporter: PowerReporter) {
        state.withLock { $0.reporter = reporter }
        queue.async { [self] in
            // Before the first check, so no change falls between the two.
            follow("polkit's changes") { () throws(DBusServiceError) in
                [try polkit.observeChanges { [weak self] in self?.queueRefresh() }]
            }
            switch peer {
            case .session(let manager):
                follow("the session manager's owner") { () throws(GnomeSessionError) in
                    [try manager.observeOwner { [weak self] in self?.queueRefresh() }]
                }
            case .system:
                follow("logind's sessions") { () throws(DBusServiceError) in
                    try logind.observeSessionList { [weak self] in self?.queueRefresh() }
                }
            }
            refreshAvailability()
        }
    }

    /// Keeps the subscriptions `subscribe` makes; when it fails, availability is rechecked only on each
    /// request.
    private func follow<Failure: Error>(_ what: String, _ subscribe: () throws(Failure) -> [DBusSubscription]) {
        do throws(Failure) {
            let subscriptions = try subscribe()
            state.withLock { $0.subscriptions += subscriptions }
        } catch {
            logger.log(
                .error,
                """
                Power cannot follow \(what, privacy: .public); it rechecks on each request: \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// The peer's session state, as the logind watcher delivers it; nil while it has no session. A session
    /// peer offers power only while its session holds the console; the system peer ignores it.
    public func setPeerState(_ peerState: PeerSessionState?) {
        guard case .session = peer else { return }
        let onConsole = peerState?.console == .on
        let changed = state.withLock { state in
            defer { state.onConsole = onConsole }
            return state.onConsole != onConsole && state.reporter != nil
        }
        if changed { queueRefresh() }
    }

    /// Rechecks the availability, reports `.blocked` while any app holds unsaved work, then asks logind.
    public func perform(_ id: PowerRequestID, _ action: PowerAction) {
        state.withLock { _ = $0.unclaimed.insert(id) }
        queue.async { [self] in run(id, action) }
    }

    /// Reports `.cancelled` while logind has not been asked; otherwise the request's own report follows.
    public func cancel(_ id: PowerRequestID) {
        guard claim(id), let reporter = state.withLock(\.reporter) else { return }
        logger.log(.notice, "Power request \(id.rawValue) was cancelled before logind was asked")
        reporter.report(.cancelled(id))
    }

    // MARK: Availability

    /// What the adapter offers now, and how it refuses an action it does not offer.
    private struct Verdict {
        var availability: Availability<PowerOffer>
        var refusal: WireError
        var level: KernovaLogLevel = .notice
    }

    private func evaluate() -> Verdict {
        switch peer {
        case .session(let manager):
            if let unseen = sessionManagerAbsence(manager) { return unseen }
            if !state.withLock(\.onConsole) {
                return Verdict(
                    availability: .absent(.notOnConsole, debugDetail: "the session does not hold the console"),
                    refusal: WireError(.powerNotOnConsole))
            }
        case .system:
            if let unseen = desktopSessionAbsence() { return unseen }
        }
        var actions: [PowerAction] = []
        for (action, actionID) in Self.polkitActions {
            do throws(DBusServiceError) {
                if try polkit.isAuthorized(actionID) { actions.append(action) }
            } catch {
                if PolkitAuthority.isAbsent(error) {
                    let detail = "polkit is not on the system bus: \(error)"
                    return Verdict(
                        availability: .absent(.missingOsComponent, debugDetail: detail),
                        refusal: WireError(.powerNotPermitted, debugDetail: detail))
                }
                let detail = "polkit's CheckAuthorization of \(actionID) failed: \(error)"
                return Verdict(
                    availability: .absent(.notPermitted, debugDetail: detail),
                    refusal: WireError(.powerNotPermitted, debugDetail: detail), level: .error)
            }
        }
        guard !actions.isEmpty else {
            let detail = "polkit authorizes neither power-off nor reboot"
            return Verdict(
                availability: .absent(.notPermitted, debugDetail: detail),
                refusal: WireError(.powerNotPermitted, debugDetail: detail))
        }
        return Verdict(
            availability: .available(PowerOffer(actions: actions, asksAppsToQuit: false)),
            refusal: WireError(.powerNotPermitted, debugDetail: "polkit does not authorize this action"))
    }

    /// `UNSAVED_WORK_UNSEEN` unless a session manager serves `org.gnome.SessionManager`, whose inhibitor list
    /// is the session's unsaved work.
    private func sessionManagerAbsence(_ manager: GnomeSessionManager) -> Verdict? {
        do throws(GnomeSessionError) {
            guard try !manager.hasOwner() else { return nil }
            return Self.unseen(
                "nothing owns \(GnomeSessionManager.busName), so nothing lists the session's unsaved work")
        } catch {
            return Self.unseen(
                "the session bus cannot say whether \(GnomeSessionManager.busName) has an owner: \(error)", .error)
        }
    }

    /// `UNSAVED_WORK_UNSEEN` while any desktop session runs: a system service cannot read its session bus.
    private func desktopSessionAbsence() -> Verdict? {
        do throws(DBusServiceError) {
            let desktops = try logind.desktopSessions()
            guard !desktops.isEmpty else { return nil }
            let ids = desktops.map(\.id).joined(separator: ", ")
            return Self.unseen("desktop session \(ids) runs, and the system peer cannot see its unsaved work")
        } catch {
            return Self.unseen("logind's sessions cannot be read: \(error)", .error)
        }
    }

    private static func unseen(_ detail: String, _ level: KernovaLogLevel = .notice) -> Verdict {
        Verdict(
            availability: .absent(.unsavedWorkUnseen, debugDetail: detail),
            refusal: WireError(.featureUnavailable, absence: .unsavedWorkUnseen, debugDetail: detail), level: level)
    }

    /// Evaluates the availability, reporting it when it differs from the last report.
    @discardableResult
    private func refreshAvailability() -> Verdict {
        dispatchPrecondition(condition: .onQueue(queue))
        state.withLock { $0.refreshQueued = false }
        let verdict = evaluate()
        let reporter = state.withLock { state -> PowerReporter? in
            guard let reporter = state.reporter, state.reported != verdict.availability else { return nil }
            state.reported = verdict.availability
            return reporter
        }
        guard let reporter else { return verdict }
        switch verdict.availability {
        case .available(let offer):
            logger.log(.notice, "Power is available: \(String(describing: offer.actions), privacy: .public)")
        case .absent(let reason, let detail):
            logger.log(
                verdict.level,
                "Power is absent, \(String(describing: reason), privacy: .public): \(detail, privacy: .public)")
        }
        reporter.report(.availability(verdict.availability))
        return verdict
    }

    /// Queues one refresh, unless one is queued and has not yet started.
    private func queueRefresh() {
        let queued = state.withLock { state in
            defer { state.refreshQueued = true }
            return state.refreshQueued
        }
        if !queued { queue.async { [self] in refreshAvailability() } }
    }

    // MARK: Requests

    /// Takes `id`'s terminal report for the caller; false when another caller has it.
    private func claim(_ id: PowerRequestID) -> Bool {
        state.withLock { $0.unclaimed.remove(id) != nil }
    }

    /// Runs `report` with the reporter when the caller claims `id`'s terminal report.
    private func conclude(_ id: PowerRequestID, _ report: (PowerReporter) -> Void) {
        guard claim(id), let reporter = state.withLock(\.reporter) else { return }
        report(reporter)
    }

    private func run(_ id: PowerRequestID, _ action: PowerAction) {
        let name = String(describing: action)
        let verdict = refreshAvailability()
        guard verdict.availability.params?.actions.contains(action) == true else {
            return conclude(id) { reporter in
                logger.log(
                    .notice,
                    """
                    Power request \(id.rawValue) to \(name, privacy: .public) is refused: \
                    \(verdict.refusal.debugDetail, privacy: .public)
                    """)
                reporter.report(.refused(id, verdict.refusal))
            }
        }

        // The only guard against unsaved work where logind lets this caller through the lock: see
        // `Logind.powerOff(timeout:)`.
        let blocking: [AppValue]
        do throws(PreCheckFailure) {
            blocking = try blockingApps()
        } catch {
            return conclude(id) { reporter in
                logger.log(
                    .error,
                    """
                    Power request \(id.rawValue) to \(name, privacy: .public) is refused: \
                    \(error.detail, privacy: .public)
                    """)
                reporter.report(.refused(id, WireError(.powerOsFailed, debugDetail: error.detail)))
            }
        }
        guard blocking.isEmpty else {
            return conclude(id) { reporter in
                reporter.report(.accepted(id))
                reportBlocked(id, name, blocking, reporter)
            }
        }

        guard claim(id), let reporter = state.withLock(\.reporter) else { return }
        do throws(DBusServiceError) {
            if action == .restart {
                try logind.reboot(timeout: powerCallTimeout)
            } else {
                try logind.powerOff(timeout: powerCallTimeout)
            }
            logger.log(.notice, "Power request \(id.rawValue): logind took the \(name, privacy: .public)")
            reporter.report(.accepted(id))
            reporter.report(.handedOff(id))
        } catch {
            settle(id, name, error, reporter)
        }
    }

    /// Reports how a power call logind did not take ended.
    private func settle(_ id: PowerRequestID, _ name: String, _ error: DBusServiceError, _ reporter: PowerReporter) {
        let failure = "Power request \(id.rawValue) to \(name)"
        switch error {
        case .call(.remote(let remote)) where remote.name == "org.freedesktop.login1.BlockedByInhibitorLock":
            reporter.report(.accepted(id))
            let blocking: [AppValue]
            do throws(PreCheckFailure) {
                blocking = try blockingApps()
            } catch {
                logger.log(.error, "The blocking apps cannot be named: \(error.detail, privacy: .public)")
                blocking = []
            }
            reportBlocked(id, name, blocking, reporter)
        case .call(.remote(let remote))
        where remote.name == "org.freedesktop.DBus.Error.AccessDenied"
            || remote.name == "org.freedesktop.DBus.Error.InteractiveAuthorizationRequired":
            logger.log(
                .notice, "\(failure, privacy: .public) is not permitted: \(remote.name, privacy: .public)")
            reporter.report(
                .refused(id, WireError(.powerNotPermitted, debugDetail: "\(remote.name): \(remote.message)")))
        case .call(.remote(let remote)):
            logger.log(
                .notice,
                "\(failure, privacy: .public) failed: \(remote.name, privacy: .public): \(remote.message, privacy: .public)"
            )
            reporter.report(.refused(id, WireError(.powerOsFailed, debugDetail: "\(remote.name): \(remote.message)")))
        case .call(.invalidMessage):
            logger.log(
                .error, "\(failure, privacy: .public) was not sent: \(String(describing: error), privacy: .public)")
            reporter.report(.refused(id, WireError(.powerOsFailed, debugDetail: "\(error)")))
        case .call(.timedOut), .call(.disconnected), .unexpectedReply, .valueMismatch, .missingProperty:
            logger.log(
                .notice,
                """
                \(failure, privacy: .public) has no answer from logind: \
                \(String(describing: error), privacy: .public)
                """)
            reporter.report(.unconfirmed(id))
        }
    }

    private func reportBlocked(_ id: PowerRequestID, _ name: String, _ apps: [AppValue], _ reporter: PowerReporter) {
        let names = apps.map(\.displayName).joined(separator: ", ")
        logger.log(
            .notice,
            "Power request \(id.rawValue) to \(name, privacy: .public) is blocked by: \(names, privacy: .public)")
        reporter.report(.blocked(id, apps))
    }

    /// Why the apps holding unsaved work could not be read.
    private struct PreCheckFailure: Error {
        var detail: String
    }

    /// The apps holding unsaved work. On a session peer: the session manager's logout inhibitors, then
    /// logind's shutdown blockers outside the session manager's own process — a package upgrade, say. On
    /// the system peer: logind's shutdown blockers.
    private func blockingApps() throws(PreCheckFailure) -> [AppValue] {
        let blockers: [LogindInhibitor]
        do throws(DBusServiceError) {
            blockers = try logind.shutdownBlockers()
        } catch {
            throw PreCheckFailure(detail: "logind's ListInhibitors failed: \(error)")
        }
        guard case .session(let manager) = peer else { return blockers.map(Self.app(holding:)) }
        do throws(GnomeSessionError) {
            let sessionApps = try manager.logoutInhibitors()
            let managerPID = try manager.ownerProcessID()
            return sessionApps + blockers.filter { $0.pid != managerPID }.map(Self.app(holding:))
        } catch {
            throw PreCheckFailure(detail: "the session manager's inhibitors cannot be read: \(error)")
        }
    }

    /// The app holding `blocker`, by its `who` and its process's command name.
    private static func app(holding blocker: LogindInhibitor) -> AppValue {
        let command = LinuxIdentity.readText("/proc/\(blocker.pid)/comm").map { String($0.prefix { $0 != "\n" }) }
        return AppValue(
            displayName: blocker.who, identifier: command ?? "", processID: Int32(truncatingIfNeeded: blocker.pid))
    }
}
#endif
