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
/// them and, for a session peer, while its session holds the console.
///
/// Every D-Bus call runs on the adapter's own serial queue.
public final class LinuxPowerAdapter: PowerAdapter {
    /// How long a power call waits for logind: under the host's 10 s acceptance deadline, so a call
    /// logind never answers ends `.unconfirmed` while the host still waits on it.
    public static let defaultPowerCallTimeout: Duration = .seconds(8)

    /// The polkit actions logind checks for each power action, without the `-multiple-sessions` and
    /// `-ignore-inhibit` variants it checks when other users are logged in or a lock is held.
    private static let polkitActions: [(action: PowerAction, id: String)] = [
        (.shutdown, "org.freedesktop.login1.power-off"), (.restart, "org.freedesktop.login1.reboot"),
    ]

    private let role: PeerRole
    private let logind: Logind
    private let polkit: PolkitAuthority
    /// The session peer's app names; nil on the system peer, which names logind's holders.
    private let gnomeSession: GnomeSessionInhibitors?
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
        var polkitChanges: DBusSubscription?
        /// Requests performed whose terminal report nobody has yet claimed. Whoever removes one reports
        /// its end: `cancel(_:)` while nothing has been asked of logind, the request's own run otherwise.
        var unclaimed: Set<PowerRequestID> = []
    }

    /// The adapter for `role`, calling logind and polkit over `systemBus`. A session peer names the apps
    /// that block a request from `gnomeSession`, or from logind where that names none.
    public init(
        role: PeerRole, systemBus: DBusBusConnection, gnomeSession: GnomeSessionInhibitors = GnomeSessionInhibitors(),
        powerCallTimeout: Duration = LinuxPowerAdapter.defaultPowerCallTimeout
    ) {
        self.role = role
        logind = Logind(connection: systemBus)
        polkit = PolkitAuthority(connection: systemBus)
        self.gnomeSession = role == .sessionPeer ? gnomeSession : nil
        self.powerCallTimeout = powerCallTimeout
    }

    deinit {
        state.withLock { $0.polkitChanges }?.cancel()
    }

    /// Follows polkit's changes and reports the first availability, on the adapter's queue.
    public func start(reporter: PowerReporter) {
        state.withLock { $0.reporter = reporter }
        queue.async { [self] in
            // Before the first check, so no change falls between the two.
            do throws(DBusServiceError) {
                let subscription = try polkit.observeChanges { [weak self] in self?.queueRefresh() }
                state.withLock { $0.polkitChanges = subscription }
            } catch {
                logger.log(
                    .error,
                    """
                    Power cannot follow polkit's changes; it rechecks on each request: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
            refreshAvailability()
        }
    }

    /// The peer's session state, as the logind watcher delivers it; nil while it has no session. A session
    /// peer offers power only while its session holds the console; the system peer ignores it.
    public func setPeerState(_ peerState: PeerSessionState?) {
        guard role == .sessionPeer else { return }
        let onConsole = peerState?.console == .on
        let changed = state.withLock { state in
            defer { state.onConsole = onConsole }
            return state.onConsole != onConsole && state.reporter != nil
        }
        if changed { queueRefresh() }
    }

    /// Rechecks polkit, reports `.blocked` while any app holds a shutdown block, then asks logind.
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
        if role == .sessionPeer, !state.withLock(\.onConsole) {
            return Verdict(
                availability: .absent(.notOnConsole, debugDetail: "the session does not hold the console"),
                refusal: WireError(.powerNotOnConsole))
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
        let blockers: [LogindInhibitor]
        do throws(DBusServiceError) {
            blockers = try logind.shutdownBlockers()
        } catch {
            return conclude(id) { reporter in
                logger.log(
                    .error,
                    """
                    Power request \(id.rawValue) to \(name, privacy: .public) is refused: logind's inhibitors \
                    cannot be read: \(String(describing: error), privacy: .public)
                    """)
                reporter.report(
                    .refused(id, WireError(.powerOsFailed, debugDetail: "ListInhibitors failed: \(error)")))
            }
        }
        guard blockers.isEmpty else {
            return conclude(id) { reporter in
                reporter.report(.accepted(id))
                reportBlocked(id, name, apps(holding: blockers), reporter)
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
            let blockers: [LogindInhibitor]
            do throws(DBusServiceError) {
                blockers = try logind.shutdownBlockers()
            } catch {
                logger.log(.error, "logind's inhibitors cannot be read: \(String(describing: error), privacy: .public)")
                blockers = []
            }
            reportBlocked(id, name, apps(holding: blockers), reporter)
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

    /// The apps that hold `blockers`: gnome-session's logout inhibitors on a session peer, else logind's
    /// holders, by `who` and their process's command name.
    private func apps(holding blockers: [LogindInhibitor]) -> [AppValue] {
        if let gnomeSession {
            do throws(GnomeSessionError) {
                let apps = try gnomeSession.logoutInhibitors()
                if !apps.isEmpty { return apps }
            } catch {
                logger.log(
                    .notice,
                    """
                    gnome-session's inhibitors cannot be read; the blocking apps are logind's holders: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
        return blockers.map { blocker in
            let command = LinuxIdentity.readText("/proc/\(blocker.pid)/comm").map { String($0.prefix { $0 != "\n" }) }
            return AppValue(
                displayName: blocker.who, identifier: command ?? "", processID: Int32(truncatingIfNeeded: blocker.pid))
        }
    }
}
#endif
