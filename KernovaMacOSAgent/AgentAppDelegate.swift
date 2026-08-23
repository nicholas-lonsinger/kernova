import AppKit
import Foundation
import KernovaKit

// Guest-side agent for macOS VMs managed by Kernova: an `.accessory` menu-bar
// app holding four long-lived, self-reconnecting vsock connections to the host
// — control, clipboard, drop, and log forwarding.

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
    private var dropAgent: VsockGuestDropAgent?
    private var controlAgent: VsockGuestControlAgent?
    private var statusItemController: AgentStatusItemController?

    /// This side's single transfer report, shared by every agent that moves
    /// files, so the one status item never has two sources deciding what it
    /// shows.
    private var transferReporter: ClipboardTransferReporter?

    /// Retained so the signal sources stay armed for the process lifetime.
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    /// Opt-out-of-App-Nap token, held only while clipboard sharing is enabled so
    /// the 0.5 s clipboard poll isn't throttled when the agent is backgrounded.
    private var appNapActivity: NSObjectProtocol?

    // MARK: - Entry point

    static func main() {
        // `--version` must work headless — install.command probes it — so it is
        // handled before any NSApplication / window-server setup.
        if CommandLine.arguments.contains("--version") {
            print("kernova-agent \(version) (\(buildNumber))")
            exit(0)
        }

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
        // Registered with `VsockLogBridge` before the startup banner, so the
        // banner itself buffers into the pre-connect ring.
        let vsockConnection = VsockHostConnection()
        VsockLogBridge.connection = vsockConnection
        KernovaLogger.forwardingSink = { level, subsystem, category, message in
            VsockLogBridge.connection?.forwardLog(
                level: level, subsystem: subsystem, category: category, message: message)
        }
        Self.logger.notice(
            "Kernova Guest Agent v\(Self.version, privacy: .public) (\(Self.buildNumber, privacy: .public)) started"
        )

        // Reclaim clipboard staging roots left by earlier agent processes —
        // staging roots are per-instance, so a live instance's sweep can never
        // reach them; only this launch-time reclaim bounds their growth.
        ClipboardFileStaging.reclaimAll()

        let transferReporter = ClipboardTransferReporter()
        transferReporter.onReportChanged = { [weak self] report in
            self?.statusItemController?.transferReportChanged(report)
        }
        let clipboardAgent = VsockGuestClipboardAgent(
            reporter: transferReporter,
            onClipboardNotice: { [weak self] in
                DispatchQueue.main.async {
                    self?.statusItemController?.clipboardNoticeRaised()
                }
            })
        let dropAgent = VsockGuestDropAgent(reporter: transferReporter)

        // `onPolicy` gates the log, clipboard and drop capabilities;
        // `onStateChange` drives the status-item icon;
        // `onHostCapabilitiesChanged` is what tells the drop client whether this
        // host has a drop listener at all.
        let controlAgent = VsockGuestControlAgent(
            onPolicy: { [weak self] policy in
                vsockConnection.setEnabled(policy.logForwardingEnabled)
                clipboardAgent.applyPolicy(
                    enabled: policy.clipboardSharingEnabled,
                    maxPasteBytes: ClipboardPasteLimit.fromPolicy(policy.clipboardMaxPasteBytes))
                dropAgent.applyPolicy(enabled: policy.dropFilesEnabled)
                Task { @MainActor in
                    self?.updateAppNap(clipboardEnabled: policy.clipboardSharingEnabled)
                }
            },
            onStateChange: { [weak self] _ in
                // Called off-main; hop to the main actor to touch the status item.
                Task { @MainActor in
                    self?.statusItemController?.connectionStateChanged()
                }
            },
            onHostCapabilitiesChanged: { [weak dropAgent] in
                dropAgent?.syncEnablement()
            }
        )

        self.vsockConnection = vsockConnection
        dropAgent.hostSupportsDrop = { [weak controlAgent] in
            controlAgent?.hostSupportsDropFiles ?? false
        }
        self.transferReporter = transferReporter
        self.clipboardAgent = clipboardAgent
        self.dropAgent = dropAgent
        self.controlAgent = controlAgent

        self.statusItemController = AgentStatusItemController(
            version: Self.version,
            connectionState: { [weak controlAgent] in controlAgent?.connectionState ?? .connecting },
            hostBundledVersion: { [weak controlAgent] in controlAgent?.hostBundledAgentVersion ?? "" },
            logForwardingEnabled: { [weak vsockConnection] in
                vsockConnection?.isLogForwardingEnabled ?? false
            },
            clipboardActivity: { [weak clipboardAgent] in clipboardAgent?.clipboardActivity ?? .disabled },
            onCancelTransfer: { [weak transferReporter] id in
                transferReporter?.cancel(id)
            },
            onQuit: { NSApp.terminate(nil) }
        )

        installSignalHandlers(
            vsockConnection: vsockConnection,
            clipboardAgent: clipboardAgent,
            dropAgent: dropAgent,
            controlAgent: controlAgent
        )

        vsockConnection.start()
        clipboardAgent.start()
        dropAgent.start()
        controlAgent.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop control first so heartbeat cessation is the cleanest going-away
        // signal to the host; clipboard, drop and log follow.
        controlAgent?.stop()
        clipboardAgent?.stop()
        dropAgent?.stop()
        vsockConnection?.stop()
        // Balance any held App-Nap activity so begin/end stays paired.
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
        dropAgent: VsockGuestDropAgent,
        controlAgent: VsockGuestControlAgent
    ) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

        // Captures the Sendable services rather than `self`, so the handler needs
        // no main-actor isolation. Must exit 0 — the LaunchAgent's
        // `KeepAlive={SuccessfulExit:false}` only keeps a clean exit quit.
        let handler: @Sendable () -> Void = {
            Self.logger.notice("Received termination signal, shutting down")
            controlAgent.stop()
            clipboardAgent.stop()
            dropAgent.stop()
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
