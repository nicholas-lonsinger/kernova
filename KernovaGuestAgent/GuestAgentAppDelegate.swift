import AppKit
import Foundation

// KernovaGuestAgent
//
// A guest-side agent that runs inside macOS virtual machines managed by Kernova.
// It runs as an `.accessory` menu-bar app (an `NSStatusItem` dropdown, no Dock
// icon, no window) and maintains three long-lived vsock connections to the host:
// control (`VsockGuestControlAgent`, always-on handshake + heartbeat + policy),
// clipboard (`VsockGuestClipboardAgent`), and log forwarding (`VsockHostConnection`).
// All reconnect automatically on disconnect.
//
// Usage: KernovaGuestAgent [--version]
// Designed to run as a macOS LaunchAgent (auto-start on login, auto-restart on
// crash — see `app.kernova.agent.plist`).

@main
@MainActor
final class GuestAgentAppDelegate: NSObject, NSApplicationDelegate {
    // `nonisolated` so the (Sendable) signal handler can log without main-actor
    // isolation; `KernovaLogger` is `Sendable`, so this is safe.
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.agent", category: "GuestAgent")

    // MARK: - Version

    private static let version: String = {
        guard let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            logger.fault("Version string not found in Info.plist")
            assertionFailure("Version string not found in Info.plist")
            return "unknown"
        }
        return v
    }()

    private static let buildNumber: String = {
        guard let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            logger.fault("Build number not found in Info.plist")
            assertionFailure("Build number not found in Info.plist")
            return "unknown"
        }
        guard b != "AGENT_BUILD_NUMBER" else {
            logger.fault("Build number was not preprocessed — literal macro name found in Info.plist")
            assertionFailure("Build number was not preprocessed")
            return "unknown"
        }
        return b
    }()

    // MARK: - Services

    private var vsockConnection: VsockHostConnection?
    private var clipboardAgent: VsockGuestClipboardAgent?
    private var controlAgent: VsockGuestControlAgent?
    private var statusItemController: GuestAgentStatusItemController?

    /// Retained so the signal sources stay armed for the process lifetime.
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    /// Opt-out-of-App-Nap token, held only while clipboard sharing is enabled so
    /// the 0.5 s clipboard poll isn't throttled when the agent is backgrounded.
    private var appNapActivity: NSObjectProtocol?

    // MARK: - Entry point

    static func main() {
        // `--version` must work headless — install.command probes it — so handle it
        // before any NSApplication / window-server / status-item setup.
        if CommandLine.arguments.contains("--version") {
            print("kernova-agent \(version) (\(buildNumber))")
            exit(0)
        }

        let app = NSApplication.shared
        // Menu-bar-only: no Dock icon, no app-switcher entry. `LSUIElement` in the
        // Info.plist is the primary mechanism; this is belt-and-suspenders.
        app.setActivationPolicy(.accessory)
        let delegate = GuestAgentAppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Log forwarding — created and registered with `VsockLogBridge` before the
        // startup banner so the banner buffers into its pre-connect ring.
        let vsockConnection = VsockHostConnection()
        VsockLogBridge.connection = vsockConnection
        Self.logger.notice(
            "Kernova Guest Agent v\(Self.version, privacy: .public) (\(Self.buildNumber, privacy: .public)) started"
        )

        let clipboardAgent = VsockGuestClipboardAgent()

        // Control plane: always-on handshake/heartbeat/policy. `onPolicy` gates the
        // log + clipboard capabilities; `onStateChange` drives the status-item icon.
        let controlAgent = VsockGuestControlAgent(
            onPolicy: { [weak self] policy in
                vsockConnection.setEnabled(policy.logForwardingEnabled)
                clipboardAgent.setEnabled(policy.clipboardSharingEnabled)
                Task { @MainActor in
                    self?.updateAppNap(clipboardEnabled: policy.clipboardSharingEnabled)
                }
            },
            onStateChange: { [weak self] _ in
                // Called off-main; hop to the main actor to touch the status item.
                // The delivered state is only a trigger — the controller re-reads
                // the live state, since independently-hopped tasks aren't ordered.
                Task { @MainActor in
                    self?.statusItemController?.connectionStateChanged()
                }
            }
        )

        self.vsockConnection = vsockConnection
        self.clipboardAgent = clipboardAgent
        self.controlAgent = controlAgent

        self.statusItemController = GuestAgentStatusItemController(
            version: Self.version,
            build: Self.buildNumber,
            connectionState: { [weak controlAgent] in controlAgent?.connectionState ?? .connecting },
            hostBundledVersion: { [weak controlAgent] in controlAgent?.hostBundledAgentVersion ?? "" },
            clipboardActivity: { [weak clipboardAgent] in clipboardAgent?.clipboardActivity ?? .idle },
            onQuit: { NSApp.terminate(nil) }
        )

        installSignalHandlers(
            vsockConnection: vsockConnection,
            clipboardAgent: clipboardAgent,
            controlAgent: controlAgent
        )

        vsockConnection.start()
        clipboardAgent.start()
        controlAgent.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The Quit path (the SIGTERM path stops them in the signal handler). Stop
        // control first so heartbeat cessation is the cleanest going-away signal to
        // the host; clipboard and log follow. `stop()` is idempotent.
        controlAgent?.stop()
        clipboardAgent?.stop()
        vsockConnection?.stop()
        // Balance any held App-Nap activity so begin/end stays paired (harmless
        // at real process exit, but keeps the assertion from leaking if the
        // lifecycle ever keeps the process alive past terminate).
        updateAppNap(clipboardEnabled: false)
    }

    // MARK: - App Nap

    private func updateAppNap(clipboardEnabled: Bool) {
        if clipboardEnabled {
            guard appNapActivity == nil else { return }
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated], reason: "Kernova clipboard sync polling")
        } else if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }

    // MARK: - Signal handling

    private func installSignalHandlers(
        vsockConnection: VsockHostConnection,
        clipboardAgent: VsockGuestClipboardAgent,
        controlAgent: VsockGuestControlAgent
    ) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

        // Captures the (Sendable) services rather than `self`, so the handler needs
        // no main-actor isolation. Runs on the main queue; exits cleanly (exit code
        // 0) so the LaunchAgent's `KeepAlive={SuccessfulExit:false}` keeps it quit.
        let handler: @Sendable () -> Void = {
            Self.logger.notice("Received termination signal, shutting down")
            controlAgent.stop()
            clipboardAgent.stop()
            vsockConnection.stop()
            exit(0)
        }

        sigintSource.setEventHandler(handler: handler)
        sigtermSource.setEventHandler(handler: handler)
        sigintSource.resume()
        sigtermSource.resume()

        self.sigintSource = sigintSource
        self.sigtermSource = sigtermSource
    }
}
