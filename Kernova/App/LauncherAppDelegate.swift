import AppKit
import KernovaKit
import os

/// The short-lived foreground process Finder spawns when the user double-clicks
/// Kernova (or its Login-Items entry, or a `.kernova` bundle while the resident
/// agent is down).
///
/// It is NOT the resident app: it registers the launch-at-login agent if needed,
/// forwards any double-clicked `.kernova` bundle paths and asks the running agent
/// to import them and/or bring its GUI forward (connecting to `…xpc`
/// demand-launches the agent via launchd if the user force-killed it), then
/// exits. The resident agent — a separate launchd-managed process — owns the VMs
/// and the `…xpc` Mach service. Routing through the agent (rather than
/// becoming the app itself) is what makes a post-kill double-click resurrect the
/// *launchd-managed* process instead of a foreground Finder process that couldn't
/// host the Mach service (issue #439: this also means a cold document-open
/// double-click no longer drops the open bundle on the floor).
@MainActor
final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    // `nonisolated` so the off-main XPC reply/error closures can log and exit.
    nonisolated private static let logger = Logger(subsystem: "app.kernova", category: "Launcher")

    /// Hard cap so a wedged XPC round-trip can't leave the launcher resident.
    private static let summonTimeout: DispatchTimeInterval = .seconds(10)

    /// Held for the call's lifetime so XPC doesn't tear the connection down early.
    private var connection: NSXPCConnection?

    /// `.kernova` paths accumulated from `application(_:open:)`, forwarded to the
    /// resident agent once launch finishes (issue #439).
    ///
    /// RATIONALE: on a cold document-open launch, AppKit delivers the open-document
    /// Apple event before `applicationDidFinishLaunching` — "document double-clicks
    /// have already been processed when applicationDidFinishLaunching is issued"
    /// (Cocoa startup ordering: applicationWillFinishLaunching starts the run loop,
    /// document-open events are drained before it returns, then
    /// applicationDidFinishLaunching fires). So reading this synchronously in
    /// `applicationDidFinishLaunching` is safe without a deferred/coalescing step.
    private var pendingVMPaths: [String] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingVMPaths.append(
            contentsOf:
                urls
                .filter { $0.pathExtension == VMStorageService.bundleExtension }
                .map { $0.path(percentEncoded: false) })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = KernovaBackgroundAgent.registerIfNeeded()

        // A disabled login item can't host `…xpc`, so summoning would hang.
        // Surface it and stop — do not masquerade as the service host.
        if status == .requiresApproval {
            Self.logger.warning("Agent requires approval; prompting to open Login Items & Extensions")
            presentApprovalNeededAndExit(hadPendingVMs: !pendingVMPaths.isEmpty)
            return
        }

        summonAgentGUI(vmPaths: pendingVMPaths)
    }

    /// Asks the resident agent to import any forwarded `.kernova` bundles and/or
    /// show its GUI over its `…xpc` service.
    ///
    /// Connecting demand-launches the agent via launchd if it was killed.
    private func summonAgentGUI(vmPaths: [String]) {
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

        let onAcknowledged: @Sendable () -> Void = {
            Self.logger.notice("Agent acknowledged summon")
            Self.exitLauncher(0)
        }
        if vmPaths.isEmpty {
            proxy.showUserInterface(reply: onAcknowledged)
        } else {
            proxy.openVMs(paths: vmPaths, reply: onAcknowledged)
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
    private func presentApprovalNeededAndExit(hadPendingVMs: Bool) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow Kernova in the Background"
        alert.informativeText =
            hadPendingVMs
            ? "Kernova runs a background agent so its virtual machines keep running and clipboard sharing works without a window open. Turn Kernova on in System Settings → General → Login Items & Extensions, then open your virtual machine again."
            : "Kernova runs a background agent so its virtual machines keep running and clipboard sharing works without a window open. Turn Kernova on in System Settings → General → Login Items & Extensions, then open Kernova again."
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
