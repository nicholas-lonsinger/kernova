#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import CKernovaAgentVersion
// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch does not.
@preconcurrency import Dispatch
import KernovaAgentCore
import KernovaAgentInstall
import KernovaAgentRuntime
import KernovaConsole
import KernovaDBus
import KernovaDigest
import KernovaLogging
import KernovaPlatformLinux
import KernovaSynchronization

/// The process: parses the command, then runs a peer until it stops for good, or answers and exits.
enum AgentShell {
    private static let logger = KernovaLogger(subsystem: "app.kernova.agent", category: "Agent")
    /// The queue the shell's own work runs on.
    private static let queue = DispatchQueue(label: "app.kernova.agent.shell")
    /// What the process holds for as long as it runs.
    private static let held = Locked<Held>(Held())

    /// The peer's dialer: `UnansweredDialer` in a build `Tools/build-linux-guest-agent.sh` gives the
    /// hang-before-Hello fault, from `KERNOVA_AGENT_FAULT`, Debug only.
    private static var dialer: any TransportDialer {
        #if KERNOVA_AGENT_FAULT_HANG_BEFORE_HELLO
        UnansweredDialer(logger: logger)
        #else
        LinuxVsockDialer()
        #endif
    }

    private struct Held: Sendable {
        var runtime: PeerAgentRuntime?
        var bus: DBusBusConnection?
        var watcher: LogindPeerStateWatcher?
        var termination: (any DispatchSourceSignal)?
    }

    static func main(_ arguments: [String]) -> Never {
        guard let command = AgentCommand.parse(Array(arguments.dropFirst())) else {
            Console.notice(AgentCommand.usage)
            exit(64)  // EX_USAGE
        }
        let label = String(cString: kernova_agent_version_label())
        switch command {
        case .version:
            Console.out(label)
            exit(0)
        case .selfTest:
            selfTest(label: label)
        case .session:
            runPeer(.sessionPeer, label: label)
        case .system:
            runPeer(.systemPeer, label: label)
        case .install(let request):
            runInstaller(request, uninstalling: false, label: label)
        case .uninstall(let request):
            runInstaller(request, uninstalling: true, label: label)
        case .rollbackCheck(let scope):
            runRollbackCheck(scope)
        }
    }

    /// The status a peer exits with to relaunch: its unit's `RestartForceExitStatus=` (EX_TEMPFAIL).
    static let relaunchStatus: Int32 = 75

    /// Prints what this binary would claim, so an installer can tell a staged payload runs here.
    private static func selfTest(label: String) -> Never {
        do throws(LinuxIdentityError) {
            let claim = try LinuxIdentity.current(role: .sessionPeer, versionLabel: label)
            Console.out("version: \(claim.versionLabel)")
            Console.out("payload-sha256: \(lowercaseHex(claim.payloadHash))")
            Console.out("scope: \(claim.scope)")
            Console.out("architecture: \(claim.architecture)")
            Console.out("os: \(claim.osDistribution) \(claim.osVersion)")
            Console.out("kernel: \(claim.osBuild)")
            exit(0)
        } catch {
            Console.notice("kernova-agent: cannot read its own executable: \(error)")
            exit(1)
        }
    }

    /// Runs the peer for `role`: reads its identity, then holds a connection to the host through
    /// `PeerAgentRuntime` for as long as logind gives it a session to serve, forwarding its own records
    /// when the host's policy turns LOGS on.
    private static func runPeer(_ role: PeerRole, label: String) -> Never {
        // First, so every record the process makes reaches the ring, the start notice included.
        let logs = LogForwarding()
        KernovaLogger.bootstrapProcessSink(logs.sink)
        let name = role == .systemPeer ? "system" : "session"
        let claim: PeerClaim
        do throws(LinuxIdentityError) {
            claim = try LinuxIdentity.current(role: role, versionLabel: label)
        } catch {
            fail("The \(name) peer cannot read its own executable: \(String(describing: error), privacy: .public)")
        }
        logger.log(
            .notice,
            """
            The \(name, privacy: .public) peer \(label, privacy: .public) starts, scope \
            \(String(describing: claim.scope), privacy: .public), payload \(lowercaseHex(claim.payloadHash), privacy: .public)
            """)
        let bus: DBusBusConnection
        do throws(DBusConnectError) {
            bus = try DBusBusConnection(bus: .system)
        } catch {
            fail("The \(name) peer cannot reach the system bus: \(String(describing: error), privacy: .public)")
        }
        held.withLock { $0.bus = bus }
        let logind = Logind(connection: bus)
        let update = updateInstaller(scope: claim.scope, label: label)
        // Dials nothing until the watcher's first state.
        let runtime = PeerAgentRuntime(
            claim: claim, state: nil, registry: PeerFeatureRegistry(logs: logs, update: update),
            dialer: dialer,
            scheduler: SystemScheduler(), logger: logger,
            handlers: PeerAgentRuntime.Handlers(
                event: { event in
                    // A PolicyUpdate follows the host's Hello: this version is connected, so it keeps itself.
                    if case .policyReceived = event { update?.confirm() }
                },
                stop: { reason in
                    logger.log(.notice, "The peer stops for good: \(String(describing: reason), privacy: .public)")
                    exit(0)
                }))
        held.withLock { $0.runtime = runtime }
        installTermination()
        runtime.start()

        // Its own queue: a logind read can block for the bus's reply timeout, and SIGTERM must not wait on it.
        let watchQueue = DispatchQueue(label: "app.kernova.agent.logind")
        let hasState = Locked(false)
        let apply: @Sendable (Result<PeerSessionState?, DBusServiceError>) -> Void = { result in
            switch result {
            case .success(let state):
                hasState.withLock { $0 = true }
                logState(state, role: role)
                runtime.setPeerState(state)
            case .failure(let error) where !hasState.withLock({ $0 }):
                // Nothing to keep, and a change that would reread may never come — a headless guest's
                // seat0 can stay as it is — so the process exits and its unit's restart reads again.
                fail(
                    "The \(name) peer cannot read its first session state: \(String(describing: error), privacy: .public)"
                )
            case .failure(let error):
                logger.log(
                    .error,
                    """
                    The \(name, privacy: .public) peer cannot read its session state; it keeps the last one \
                    until logind's next change: \(String(describing: error), privacy: .public)
                    """)
            }
        }
        let watcher: LogindPeerStateWatcher
        do throws(DBusServiceError) {
            watcher =
                role == .sessionPeer
                ? try LogindPeerStateWatcher.sessionPeer(logind, uid: getuid(), on: watchQueue, apply)
                : try LogindPeerStateWatcher.systemPeer(logind, on: watchQueue, apply)
        } catch {
            fail("The \(name) peer cannot follow its session in logind: \(String(describing: error), privacy: .public)")
        }
        held.withLock { $0.watcher = watcher }
        dispatchMain()
    }

    /// The installer of the install this executable runs from; nil when it runs from none, as a development
    /// build run in place does, which then advertises UPDATE absent.
    private static func updateInstaller(scope: InstallScope, label: String) -> SlotUpdateInstaller? {
        guard scope != .unspecified, let running = LinuxIdentity.runningSlot() else { return nil }
        let root: SlotRoot
        do throws(SlotRoot.Failure) {
            root = try SlotRoot(path: running.root)
        } catch {
            logger.log(.error, "Cannot open the install's root: \(String(describing: error), privacy: .public)")
            return nil
        }
        return SlotUpdateInstaller(
            root: root, runningSlot: running.slot, lander: ExecutableLander(), logger: logger,
            onSwitched: {
                logger.log(.notice, "The peer relaunches into the update")
                guard let runtime = held.withLock({ $0.runtime }) else { exit(relaunchStatus) }
                runtime.close { exit(relaunchStatus) }
            },
            onConfirmed: {
                if scope == .user { refreshUserUnits(root: running.root, label: label) }
            })
    }

    /// Rewrites the user scope's units and autostart entry that differ from what this binary writes, logging
    /// each one it wrote.
    private static func refreshUserUnits(root: String, label: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let config = InstallLayout.configHome(environment: environment) else {
            return logger.log(.error, "Cannot rewrite the user units: neither XDG_CONFIG_HOME nor HOME is set")
        }
        // The path the install wrote the units with, from the manager's environment this service shares.
        let layout = InstallLayout.user(
            root: LinuxIdentity.userInstallRoot(environment: environment) ?? root, configHome: config)
        let installer = LinuxInstall.installer(stagingRoot: "", runsSystemd: true, label: label, account: nil)
        do throws(Installer.Failure) {
            let written = try installer.run(.refreshUnits(layout))
            if !written.isEmpty {
                logger.log(
                    .notice,
                    "Rewrote the user units for this version: \(written.joined(separator: ", "), privacy: .public)")
            }
        } catch {
            logger.log(.error, "Cannot rewrite the user units: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs the rollback check once for `scope`'s install, the one this executable sits in, then exits: 0
    /// when it ran, 1 when it failed.
    private static func runRollbackCheck(_ scope: InstallScope) -> Never {
        guard let running = LinuxIdentity.runningSlot() else {
            Console.notice("kernova-agent: rollback-check runs only from an installed slot")
            exit(1)
        }
        let root: SlotRoot
        do throws(SlotRoot.Failure) {
            root = try SlotRoot(path: running.root)
        } catch {
            fail("The rollback check failed: \(String(describing: error), privacy: .public)")
        }
        let check = RollbackCheck(
            root: root, serviceManager: SystemdServiceManager(scope: scope),
            kill: { pid in _ = kill(pid_t(pid), SIGKILL) })
        exit(check.run(logger: logger) ? 0 : 1)
    }

    private static func logState(_ state: PeerSessionState?, role: PeerRole) {
        guard let state else {
            return logger.log(.notice, "The user has no display session: the session peer waits for one")
        }
        let session = role == .sessionPeer ? state.sessionID : state.consoleSessionID
        logger.log(
            .notice,
            """
            Session state: console \(String(describing: state.console), privacy: .public), session \
            \(session.isEmpty ? "none" : session, privacy: .public)
            """)
    }

    /// On SIGTERM — systemd's stop — closes the connection with `SHUTTING_DOWN`, then exits 0.
    private static func installTermination() {
        // No SIG_IGN first, as on Darwin: Linux's libdispatch installs its own disposition when the source
        // registers, and ignoring the signal until then would drop a SIGTERM that arrives in between.
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler {
            guard let runtime = held.withLock({ $0.runtime }) else { exit(0) }
            runtime.close { exit(0) }
        }
        source.resume()
        held.withLock { $0.termination = source }
    }

    private static func fail(_ message: LogMessage) -> Never {
        logger.log(.error, message)
        exit(1)
    }
}
#endif
