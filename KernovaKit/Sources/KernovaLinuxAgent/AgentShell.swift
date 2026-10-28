#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import CKernovaAgentVersion
// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch does not.
@preconcurrency import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
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

    private struct Held: Sendable {
        var runtime: PeerAgentRuntime?
        var bus: DBusBusConnection?
        var watcher: LogindPeerStateWatcher?
        var termination: (any DispatchSourceSignal)?
    }

    static func main(_ arguments: [String]) -> Never {
        guard let command = AgentCommand.parse(Array(arguments.dropFirst())) else {
            writeError(AgentCommand.usage)
            exit(64)  // EX_USAGE
        }
        let label = String(cString: kernova_agent_version_label())
        switch command {
        case .version:
            print(label)
            exit(0)
        case .selfTest:
            selfTest(label: label)
        case .session:
            runPeer(.sessionPeer, label: label)
        case .system:
            runPeer(.systemPeer, label: label)
        }
    }

    /// Prints what this binary would claim, so an installer can tell a staged payload runs here.
    private static func selfTest(label: String) -> Never {
        do throws(LinuxIdentityError) {
            let claim = try LinuxIdentity.current(role: .sessionPeer, versionLabel: label)
            print("version: \(claim.versionLabel)")
            print("payload-sha256: \(lowercaseHex(claim.payloadHash))")
            print("scope: \(claim.scope)")
            print("architecture: \(claim.architecture)")
            print("os: \(claim.osDistribution) \(claim.osVersion)")
            print("kernel: \(claim.osBuild)")
            exit(0)
        } catch {
            writeError("kernova-agent: cannot read its own executable: \(error)")
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
        #if KERNOVA_AGENT_FAULT_HANG_BEFORE_HELLO
        logger.log(.notice, "This build carries the hang-before-Hello fault: it never dials")
        while true { pause() }
        #endif

        let bus: DBusBusConnection
        do throws(DBusConnectError) {
            bus = try DBusBusConnection(bus: .system)
        } catch {
            fail("The \(name) peer cannot reach the system bus: \(String(describing: error), privacy: .public)")
        }
        held.withLock { $0.bus = bus }
        let logind = Logind(connection: bus)
        // Dials nothing until the watcher's first state.
        let runtime = PeerAgentRuntime(
            claim: claim, state: nil, registry: PeerFeatureRegistry(logs: logs), dialer: LinuxVsockDialer(),
            scheduler: SystemScheduler(), logger: logger,
            handlers: PeerAgentRuntime.Handlers { reason in
                logger.log(.notice, "The peer stops for good: \(String(describing: reason), privacy: .public)")
                exit(0)
            })
        held.withLock { $0.runtime = runtime }
        installTermination()
        runtime.start()

        // Its own queue: a logind read can block for the bus's reply timeout, and SIGTERM must not wait on it.
        let watchQueue = DispatchQueue(label: "app.kernova.agent.logind")
        let apply: @Sendable (Result<PeerSessionState?, LogindError>) -> Void = { result in
            switch result {
            case .success(let state):
                logState(state, role: role)
                runtime.setPeerState(state)
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
        do throws(LogindError) {
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

    private static func writeError(_ text: String) {
        var line = text + "\n"
        line.withUTF8 { bytes in _ = write(2, bytes.baseAddress, bytes.count) }
    }
}
#endif
