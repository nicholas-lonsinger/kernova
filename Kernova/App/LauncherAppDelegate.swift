import AppKit
import KernovaKit
import os

/// The short-lived foreground process Finder spawns when the user double-clicks
/// Kernova (or its Login-Items entry).
///
/// It is NOT the resident app: it registers the launch-at-login agent if needed,
/// asks the running agent to bring its GUI forward (connecting to `…xpc`
/// demand-launches the agent via launchd if the user force-killed it), then
/// exits. The resident agent — a separate launchd-managed process — owns the VMs
/// and the `…xpc` Mach service. Routing through the agent (rather than
/// becoming the app itself) is what makes a post-kill double-click resurrect the
/// *launchd-managed* process instead of a foreground Finder process that couldn't
/// host the Mach service.
@MainActor
final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    // `nonisolated` so the off-main XPC reply/error closures can log and exit.
    nonisolated private static let logger = Logger(subsystem: "app.kernova", category: "Launcher")

    /// Hard cap so a wedged XPC round-trip can't leave the launcher resident.
    private static let summonTimeout: DispatchTimeInterval = .seconds(10)

    /// Held for the call's lifetime so XPC doesn't tear the connection down early.
    private var connection: NSXPCConnection?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = KernovaBackgroundAgent.registerIfNeeded()

        // A disabled login item can't host `…xpc`, so summoning would hang.
        // Surface it and stop — do not masquerade as the service host.
        if status == .requiresApproval {
            Self.logger.warning("Agent requires approval; prompting to open Login Items & Extensions")
            presentApprovalNeededAndExit()
            return
        }

        summonAgentGUI()
    }

    /// Asks the resident agent to show its GUI over its `…xpc` service.
    ///
    /// Connecting demand-launches the agent via launchd if it was killed.
    private func summonAgentGUI() {
        let connection = NSXPCConnection(
            machServiceName: ClipboardFileProviderConfig.host.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: KernovaHostRelay.self)
        // Only the genuine Kernova-team agent may answer this summon.
        connection.setCodeSigningRequirement(KernovaHostRelayIdentity.mainAppRequirement)
        connection.resume()
        self.connection = connection

        let proxy =
            connection.remoteObjectProxyWithErrorHandler { error in
                Self.logger.error("Summon failed: \(error.localizedDescription, privacy: .public)")
                Self.exitLauncher(1)
            } as? KernovaHostRelay
        guard let proxy else { Self.exitLauncher(1) }

        proxy.showUserInterface {
            Self.logger.notice("Agent acknowledged showUserInterface")
            Self.exitLauncher(0)
        }

        // Backstop: never outlive a wedged round-trip (XPC invokes exactly one of
        // the reply or the error handler, so this only fires if neither arrives).
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.summonTimeout) {
            Self.logger.error("Summon timed out")
            Self.exitLauncher(1)
        }
    }

    /// Briefly becomes a regular app to show an alert pointing the user at Login
    /// Items & Extensions, then exits.
    private func presentApprovalNeededAndExit() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow Kernova in the Background"
        alert.informativeText =
            "Kernova runs a background agent so its virtual machines keep running and clipboard sharing works without a window open. Turn Kernova on in System Settings → General → Login Items & Extensions, then open Kernova again."
        alert.addButton(withTitle: "Open Login Items & Extensions")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            KernovaBackgroundAgent.openLoginItemsSettings()
        }
        Self.exitLauncher(0)
    }

    // `nonisolated` so the off-main XPC closures can terminate the launcher.
    nonisolated private static func exitLauncher(_ code: Int32) -> Never {
        exit(code)
    }
}
