#if os(macOS)
import Darwin
import Dispatch
import Foundation
import KernovaAgentCore
import KernovaAgentInstall
import KernovaAgentRuntime
import KernovaDigest
import KernovaLogging
import KernovaSynchronization

/// Everything the macOS agent's executable does without the window server: the system peer, the installer,
/// the rollback check, and the build's packer. Each runs, then exits.
public enum MacAgentTools {
    private static let logger = KernovaLogger(subsystem: "app.kernova.macosagent", category: "Agent")
    /// What the process holds for as long as it runs.
    private static let held = Locked<Held>(Held())

    private struct Held: Sendable {
        var peer: MacAgentPeer?
        var consoleWatcher: ConsoleUserWatcher?
        var termination: (any DispatchSourceSignal)?
    }

    /// Runs `command`, one the session's app does not run itself, then exits: 0 when it did what was asked.
    public static func run(_ command: MacAgentCommand, label: String) -> Never {
        switch command {
        case .session: preconditionFailure("the session peer is the app")
        case .version:
            print(label)
            exit(0)
        case .selfTest: selfTest(label: label)
        case .system: runSystemPeer(label: label)
        case .install(let request): runInstaller(request, uninstalling: false, label: label)
        case .uninstall(let request): runInstaller(request, uninstalling: true, label: label)
        case .rollbackCheck(let scope): runRollbackCheck(scope)
        case .stopService(let target):
            guard LaunchdStop.stop(target) else {
                writeError("Kernova Guest Agent: launchd still runs \(target)")
                exit(1)
            }
            exit(0)
        case .packPayload(let app, let output): pack(app, to: output)
        }
    }

    /// Prints what this executable would claim, so an install can tell a landed payload runs here.
    private static func selfTest(label: String) -> Never {
        let claim = DarwinIdentity.current(role: .sessionPeer, versionLabel: label)
        print("version: \(claim.versionLabel)")
        print("payload-sha256: \(claim.payloadHash.isEmpty ? "none" : lowercaseHex(claim.payloadHash))")
        print("scope: \(claim.scope)")
        print("architecture: \(claim.architecture)")
        print("os: macOS \(claim.osVersion) (\(claim.osBuild))")
        exit(0)
    }

    // MARK: The system peer

    /// Runs the system peer: a "For everyone" install's daemon, reporting the console from the dynamic store and
    /// forwarding its own records when the host's policy turns LOGS on, until SIGTERM.
    private static func runSystemPeer(label: String) -> Never {
        let logs = LogForwarding()
        KernovaLogger.bootstrapProcessSink(logs.sink)
        let peer = MacAgentPeer(role: .systemPeer, label: label, logs: logs, state: nil)
        guard peer.claim.scope == .system else {
            logger.log(.error, "The system peer runs only from the install for everyone")
            exit(1)
        }
        held.withLock { $0.peer = peer }
        installTermination { peer.exit(status: 0) }
        peer.start()
        let watcher = ConsoleUserWatcher(queue: DispatchQueue(label: "app.kernova.macosagent.console")) { state in
            logger.log(
                .notice, "Console state: \(String(describing: state.console), privacy: .public)")
            peer.setPeerState(state)
        }
        guard let watcher else {
            logger.log(.error, "The system peer cannot follow the console user")
            exit(1)
        }
        held.withLock { $0.consoleWatcher = watcher }
        dispatchMain()
    }

    /// On SIGTERM — launchd's stop — runs `stop`, which closes the connection and exits.
    public static func installTermination(_ stop: @escaping @Sendable () -> Void) {
        // Ignored first: on Darwin a signal source only observes, and the default action would end the process
        // before the connection closes.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler(handler: stop)
        source.resume()
        held.withLock { $0.termination = source }
    }

    // MARK: Install

    /// Installs or uninstalls `request`'s scope from the payload beside this app bundle, or the one it names,
    /// printing each step as it takes it.
    private static func runInstaller(
        _ request: MacAgentCommand.InstallRequest, uninstalling: Bool, label: String
    ) -> Never {
        let scope = request.scope == .system ? "the agent for everyone" : "the agent for this user"
        do {
            guard let tool = DarwinIdentity.executablePath() else {
                throw MacInstallRefusal.wrongUser("this executable cannot find its own path")
            }
            let layout = try MacInstallLayout.layout(
                for: request.scope, dryRun: request.dryRun, effectiveUID: geteuid(),
                home: ProcessInfo.processInfo.environment["HOME"], consoleUserID: DarwinSessionState.consoleUserID())
            let plan: InstallPlan =
                uninstalling ? .uninstall(layout, stopTool: tool) : .install(layout, stopTool: tool)
            if request.dryRun {
                let verb = uninstalling ? "uninstall" : "install"
                let heading = "KernovaMacOSAgent \(verb)\(request.scope == .system ? " --system" : "") will:"
                for line in InstallPlan.dryRun(plan, heading: heading) { print(line) }
                exit(0)
            }
            let installer = Installer(
                stagingRoot: "", runsCommands: true, payloadSource: request.payload ?? payloadBeside(tool),
                lander: MacAgentPeer.lander, versionLabel: label, account: nil)
            try installer.run(plan) { print("Kernova Guest Agent: \($0)") }
            print(
                uninstalling
                    ? "Kernova Guest Agent: removed \(scope)." : "Kernova Guest Agent: installed \(scope), \(label).")
            exit(0)
        } catch {
            writeError("Kernova Guest Agent: cannot \(uninstalling ? "remove" : "install") \(scope): \(error)")
            exit(1)
        }
    }

    /// `agent.payload` in the directory holding the app bundle `executable` runs from: the installer disk's root.
    static func payloadBeside(_ executable: String) -> String {
        let bundle = executable.dropLast(("/" + MacInstallLayout.executable).count)
        let directory = bundle.split(separator: "/", omittingEmptySubsequences: false).dropLast()
        return directory.joined(separator: "/") + "/" + payloadName
    }

    /// The update payload's name on the installer disk and in the host's bundle.
    public static let payloadName = "agent.payload"

    // MARK: Rollback

    /// Runs the rollback check once for `scope`'s install, the one this executable sits in: 0 when it ran.
    private static func runRollbackCheck(_ scope: InstallScope) -> Never {
        guard let running = DarwinIdentity.runningSlot() else {
            writeError("Kernova Guest Agent: rollback-check runs only from an installed slot")
            exit(1)
        }
        let root: SlotRoot
        do throws(SlotRoot.Failure) {
            root = try SlotRoot(path: running.root)
        } catch {
            logger.log(.error, "The rollback check failed: \(String(describing: error), privacy: .public)")
            exit(1)
        }
        let check = RollbackCheck(
            root: root, serviceManager: LaunchdServiceManager(label: MacInstallLayout.updatingLabel(scope)),
            kill: { pid in _ = kill(pid_t(pid), SIGKILL) })
        exit(check.run(logger: logger) ? 0 : 1)
    }

    // MARK: Packing

    /// Packs the app bundle at `app` as the update payload at `output`.
    private static func pack(_ app: String, to output: String) -> Never {
        guard FileManager.default.createFile(atPath: output, contents: nil),
            let handle = FileHandle(forWritingAtPath: output)
        else {
            writeError("Kernova Guest Agent: cannot create \(output)")
            exit(1)
        }
        do {
            try UpdatePayloadPacker.pack(directoryAt: app) { try handle.write(contentsOf: $0) }
            try handle.close()
            exit(0)
        } catch {
            writeError("Kernova Guest Agent: cannot pack \(app): \(error)")
            exit(1)
        }
    }

    static func writeError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
#endif
