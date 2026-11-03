import AppKit
import Foundation
import KernovaAgentRuntime
import KernovaKit
import KernovaLogging
import KernovaPlatformDarwin
import KernovaSynchronization

// Guest-side agent for macOS VMs managed by Kernova. Run with no arguments, or
// `session`, it is the session peer: an `.accessory` menu-bar app holding the
// v2 peer's connection to the host, which lands drops, beside the clipboard,
// drag-out and control channels. Every other command — the system peer, the installer, the
// rollback check — runs headless (`MacAgentTools`).

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

    // MARK: - Services

    private var peer: MacAgentPeer?
    private var clipboardAgent: VsockGuestClipboardAgent?
    private var dropAgent: VsockGuestDropAgent?
    private var controlAgent: VsockGuestControlAgent?
    private var statusItemController: AgentStatusItemController?

    /// Whether the host's policy forwards this guest's logs, as its control
    /// channel last said.
    private let logForwardingEnabled = Locked(false)

    /// This side's single transfer report, shared by every agent that moves
    /// files, so the one status item never has two sources deciding what it
    /// shows.
    private var transferReporter: ClipboardTransferReporter?

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
        guard let command = MacAgentCommand.parse(Array(CommandLine.arguments.dropFirst())) else {
            FileHandle.standardError.write(Data((MacAgentCommand.usage + "\n").utf8))
            exit(64)  // EX_USAGE
        }
        // Everything but the session peer runs headless, before any
        // NSApplication or window-server setup: the system peer is a daemon
        // with no window server (TN2083).
        guard command == .session else { MacAgentTools.run(command, label: versionLabel) }

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

        let peer = MacAgentPeer(
            role: .sessionPeer, label: Self.versionLabel, logs: logs, state: DarwinSessionState.sessionPeer(),
            revealDrop: { urls in
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            })
        self.peer = peer
        followSession(peer)

        // A live instance's sweep never reaches an exited agent's staging; only
        // this launch-time reclaim bounds its growth.
        let stagingRoot = ClipboardFileStaging.processRoot
        stagingRoot.reclaimAbandonedRoots()

        let transferReporter = ClipboardTransferReporter()
        transferReporter.onReportChanged = { [weak self] report in
            self?.statusItemController?.transferReportChanged(report)
        }
        let clipboardAgent = VsockGuestClipboardAgent(
            stagingRoot: stagingRoot,
            reporter: transferReporter,
            onClipboardNotice: { [weak self] in
                DispatchQueue.main.async {
                    self?.statusItemController?.clipboardNoticeRaised()
                }
            })
        let dropAgent = VsockGuestDropAgent(stagingRoot: stagingRoot, reporter: transferReporter)

        // `onPolicy` gates the clipboard and drop capabilities and says whether
        // the host forwards logs; `onStateChange` drives the status-item icon;
        // `onHostCapabilitiesChanged` is what tells the drop agent whether this
        // host has a drop listener at all, and whether it takes drags out.
        let logForwardingEnabled = self.logForwardingEnabled
        let controlAgent = VsockGuestControlAgent(
            onPolicy: { policy in
                logForwardingEnabled.withLock { $0 = policy.logForwardingEnabled }
                clipboardAgent.applyPolicy(
                    enabled: policy.clipboardSharingEnabled,
                    maxPasteBytes: ClipboardPasteLimit.fromPolicy(policy.clipboardMaxPasteBytes))
                dropAgent.applyPolicy(enabled: policy.dropFilesEnabled)
            },
            onStateChange: { [weak self] _ in
                // Called off-main; hop to the main actor to touch the status item.
                Task { @MainActor in
                    self?.statusItemController?.connectionStateChanged()
                }
            },
            onHostCapabilitiesChanged: { [weak dropAgent] capabilities in
                dropAgent?.applyHostCapabilities(capabilities)
            }
        )

        self.transferReporter = transferReporter
        self.clipboardAgent = clipboardAgent
        self.dropAgent = dropAgent
        self.controlAgent = controlAgent

        // The LaunchAgent's `KeepAlive={SuccessfulExit:false}` keeps only a
        // clean exit stopped, so 0 stops the agent and any other status
        // relaunches it.
        let shutDown: @Sendable (Int32) -> Void = { status in
            Self.logger.log(.notice, "Shutting down, exit status \(status, privacy: .public)")
            controlAgent.stop()
            clipboardAgent.stop()
            dropAgent.stop()
            peer.exit(status: status)
        }
        self.shutDown = shutDown
        let stop: @Sendable () -> Void = { shutDown(0) }

        self.statusItemController = AgentStatusItemController(
            connectionState: { [weak controlAgent] in controlAgent?.connectionState ?? .connecting },
            logForwardingEnabled: { logForwardingEnabled.withLock { $0 } },
            clipboardActivity: { [weak clipboardAgent] in clipboardAgent?.clipboardActivity ?? .disabled },
            onCancelTransfer: { [weak transferReporter] id in
                transferReporter?.cancel(id)
            },
            onQuit: stop
        )

        installSignalHandlers(stop)

        peer.start()
        clipboardAgent.start()
        dropAgent.start()
        controlAgent.start()
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
        // Stop control first so heartbeat cessation is the cleanest going-away
        // signal to the host; clipboard and drop follow.
        controlAgent?.stop()
        clipboardAgent?.stop()
        dropAgent?.stop()
    }

    // MARK: - Session state

    /// Reports the session's state again whenever a fast user switch moves this
    /// session onto the console or off it.
    private func followSession(_ peer: MacAgentPeer) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                peer.setPeerState(DarwinSessionState.sessionPeer())
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
