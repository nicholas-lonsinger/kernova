import AppKit
import Foundation
import KernovaAgentRuntime
import KernovaKit
import KernovaLogging
import KernovaPlatformDarwin

// Guest-side agent for macOS VMs managed by Kernova. Run with no arguments, or
// `session`, it is the session peer: an `.accessory` menu-bar app holding the
// v2 peer's connection to the host, which carries the clipboard, lands drops
// and serves drags out. Every other command —
// the system peer, the installer, the rollback check — runs headless (`MacAgentTools`).

@main
@MainActor
final class AgentAppDelegate: NSObject, NSApplicationDelegate {
    // `nonisolated` so the Sendable signal handler can log without main-actor
    // isolation.
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "Agent")

    // MARK: - Version

    private static let version: String = {
        guard let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            logger.log(.fault, "Version string not found in Info.plist")
            assertionFailure("Version string not found in Info.plist")
            return "unknown"
        }
        return v
    }()

    private static let buildNumber: String = {
        guard let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            logger.log(.fault, "Build number not found in Info.plist")
            assertionFailure("Build number not found in Info.plist")
            return "unknown"
        }
        guard b != "KERNOVA_BUILD_NUMBER" else {
            logger.log(.fault, "Build number was not preprocessed — literal macro name found in Info.plist")
            assertionFailure("Build number was not preprocessed")
            return "unknown"
        }
        return b
    }()

    /// The display version the agent claims: "<version> (<build>)", the shape the host labels its bundled
    /// payloads with.
    private static var versionLabel: String { "\(version) (\(buildNumber))" }

    /// The peers' dialer: `UnansweredDialer` in a build `Config/Targets/KernovaMacOSAgent.xcconfig` gives the
    /// hang-before-Hello fault, from `KERNOVA_AGENT_FAULT`.
    nonisolated private static var dialer: any TransportDialer {
        #if KERNOVA_AGENT_FAULT_HANG_BEFORE_HELLO
        #if !DEBUG
        #error("KERNOVA_AGENT_FAULT is set in a non-Debug build; only Debug builds carry it")
        #endif
        UnansweredDialer(logger: logger)
        #else
        DarwinVsockDialer()
        #endif
    }

    // MARK: - Services

    private var peer: MacAgentPeer?
    private var dragOut: GuestDragOut?
    private var clipboard: GuestClipboard?
    private var statusItemController: AgentStatusItemController?

    /// Stops every service and exits with the status given; set once the
    /// services start.
    private var shutDown: (@Sendable (Int32) -> Void)?

    /// Retained so the signal source stays armed for the process lifetime.
    private var sigintSource: DispatchSourceSignal?

    /// Keeps App Nap off for as long as the session peer runs, without
    /// keeping the guest awake. App Nap throttles the timers of an app the
    /// user isn't looking at, an accessory app included (Energy Efficiency
    /// Guide for Mac Apps, "App Nap"), which would let the connection's PING
    /// and the clipboard poll slip past the host's unresponsive mark. An
    /// activity begun with `NSActivityUserInitiatedAllowingIdleSystemSleep`
    /// exempts the process from App Nap while it is held, and still lets the
    /// system idle-sleep (`NSProcessInfo`
    /// `beginActivityWithOptions:reason:`;
    /// `NSActivityUserInitiatedAllowingIdleSystemSleep`).
    private let appNapActivity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Kernova guest agent connection")

    // MARK: - Entry point

    static func main() {
        let command = MacAgentTools.command(Array(CommandLine.arguments.dropFirst()))
        // Everything but the session peer runs headless, before any
        // NSApplication or window-server setup: the system peer is a daemon
        // with no window server (TN2083).
        guard command == .session else { MacAgentTools.run(command, label: versionLabel, dialer: dialer) }

        let app = NSApplication.shared
        // `LSUIElement` in Info.plist is the primary mechanism for this; the call
        // is belt-and-suspenders.
        app.setActivationPolicy(.accessory)
        let delegate = AgentAppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bootstrapped before the startup banner, so the banner itself buffers
        // into the pre-connect ring.
        let logs = LogForwarding()
        KernovaLogger.bootstrapProcessSink(logs.sink)
        Self.logger.log(.notice, "Kernova Guest Agent \(Self.versionLabel, privacy: .public) started")

        // A live instance's sweep never reaches an exited agent's staging; only
        // this launch-time reclaim bounds its growth, each item of the
        // clipboard naming a file there withdrawn first.
        let stagingRoot = ClipboardFileStaging.processRoot
        stagingRoot.reclaimAbandonedRoots()

        let clipboard = GuestClipboard(
            stagingRoot: stagingRoot,
            onNotice: { [weak self] in
                DispatchQueue.main.async {
                    self?.statusItemController?.clipboardNoticeRaised()
                }
            })
        let state = DarwinSessionState.sessionPeer()
        clipboard.setOnConsole(state.console == .on)
        let dragPeer = GuestDragOutRuntimePeer()
        let dragOut = GuestDragOut(peer: dragPeer, system: .live, stagingRoot: stagingRoot)
        let peer = MacAgentPeer(
            role: .sessionPeer, label: Self.versionLabel, logs: logs, state: state, dialer: Self.dialer,
            hostConnectionChanged: { [weak self] _ in
                // The controller re-reads the state, so the hops' order doesn't matter.
                Task { @MainActor in self?.statusItemController?.connectionStateChanged() }
            },
            revealDrop: { urls in
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            },
            owners: { calls in
                dragPeer.calls = calls
                return ItemFeatureOwners(clipboard: clipboard.owner(calls: calls), drag: dragOut.owner)
            })
        self.peer = peer
        self.clipboard = clipboard
        self.dragOut = dragOut
        followSession(peer, clipboard: clipboard)

        // The LaunchAgent's `KeepAlive={SuccessfulExit:false}` keeps only a
        // clean exit stopped, so 0 stops the agent and any other status
        // relaunches it.
        let shutDown: @Sendable (Int32) -> Void = { status in
            Self.logger.log(.notice, "Shutting down, exit status \(status, privacy: .public)")
            // What the clipboard holds of a file staged here goes before the process does; the next launch
            // reclaims the staging, as it does an exit that never came this way.
            MainActorBridge.async {
                dragOut.stop()
                stagingRoot.processEnding()
                peer.exit(status: status)
            }
        }
        self.shutDown = shutDown
        let stop: @Sendable () -> Void = { shutDown(0) }

        self.statusItemController = AgentStatusItemController(
            connectionState: { peer.hostConnection },
            logForwardingEnabled: { logs.isForwarding },
            clipboardActivity: { [weak clipboard] in clipboard?.activity ?? .disabled },
            onQuit: stop
        )

        installSignalHandlers(stop)

        peer.start()
    }

    /// A quit Apple event — loginwindow's as the session or the machine goes
    /// down, or a script's — exits with ``MacAgentQuit/exitStatus(for:)``'s
    /// status, so a shutdown an app cancels finds the agent relaunched.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let reason = MacAgentQuit.reason(of: event)
        Self.logger.log(
            .notice,
            "Asked to quit, reason \(reason.map { String(format: "%08x", $0) } ?? "none", privacy: .public)")
        guard let shutDown else { return .terminateNow }
        shutDown(MacAgentQuit.exitStatus(for: event))
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboard?.stop()
        dragOut?.stop()
    }

    // MARK: - Session state

    /// Reports the session's state again whenever a fast user switch moves this
    /// session onto the console or off it, to the peer and the clipboard.
    private func followSession(_ peer: MacAgentPeer, clipboard: GuestClipboard) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                let state = DarwinSessionState.sessionPeer()
                peer.setPeerState(state)
                MainActor.assumeIsolated { clipboard.setOnConsole(state.console == .on) }
            }
        }
    }

    // MARK: - Signal handling

    /// Runs `stop` on SIGTERM — launchd's stop — and on SIGINT.
    private func installSignalHandlers(_ stop: @escaping @Sendable () -> Void) {
        MacAgentTools.installTermination(stop)
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler(handler: stop)
        sigintSource.resume()
        self.sigintSource = sigintSource
    }
}
