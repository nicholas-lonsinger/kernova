import AppKit
import KernovaKit
import ServiceManagement
import os

/// The short-lived foreground process Finder spawns when the user double-clicks
/// Kernova (or its Login-Items entry, or a `.kernova` bundle while the resident
/// agent is down).
///
/// It is NOT the resident app: it reads the agent's registration status
/// (auto-registering only a Release build residing in `/Applications`, never a
/// Debug build — issue #451, so a throwaway dev copy can't pin launchd's BTM
/// record), forwards any double-clicked `.kernova` bundle paths and asks the
/// running agent to import them and/or bring its GUI forward (connecting to
/// `…xpc` demand-launches the agent via launchd if the user force-killed it),
/// then exits. The resident agent — a separate launchd-managed process — owns the VMs
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

    // MARK: - Registration gating (issue #451)

    /// What the launcher should do about the resident agent, given the build
    /// configuration, this copy's install location, and the agent's current
    /// status.
    enum LauncherAction: Equatable {
        /// Agent is enabled — summon its GUI.
        case summon
        /// Agent is registered but disabled — deep-link Login Items & Extensions.
        case promptApproval
        /// Release build in `/Applications` with no agent yet — register it, then
        /// re-evaluate on the resulting status.
        case register
        /// Debug build with no agent — a dead end (dev builds never auto-register);
        /// surface the escape hatches instead of exiting silently.
        case reportUnregisteredDebug
        /// Release build **outside** `/Applications` with no agent — refuse to
        /// self-register from a stray copy; tell the user to move to Applications.
        case reportNotInApplications
    }

    /// Decides the launcher's action purely from its inputs, so the full gating
    /// matrix is unit-testable with injected values (mirrors `AppDelegate.classifyQuit`).
    ///
    /// Build configuration is passed **in** rather than read via `#if DEBUG` here,
    /// so a Debug test host can still exercise the Release half of the matrix.
    ///
    /// `.enabled` / `.requiresApproval` are handled identically in every build (an
    /// already-registered agent is summoned, or its approval prompted, regardless
    /// of where this copy lives); only the *unregistered* case gates on build
    /// configuration and install location.
    nonisolated static func launcherAction(
        isReleaseBuild: Bool,
        isInApplications: Bool,
        status: SMAppService.Status
    ) -> LauncherAction {
        switch status {
        case .enabled:
            return .summon
        case .requiresApproval:
            return .promptApproval
        default:
            // .notRegistered / .notFound / any future case: no usable agent.
            guard isReleaseBuild else { return .reportUnregisteredDebug }
            return isInApplications ? .register : .reportNotInApplications
        }
    }

    /// Whether `bundleURL` resides under the system `/Applications` folder — the
    /// only location a Release build will auto-register from (issue #451).
    ///
    /// The trailing slash keeps a sibling like `/ApplicationsFoo` from matching. A
    /// Gatekeeper-translocated copy of a quarantined app reports a
    /// `/private/var/…/AppTranslocation/…` path, so a freshly-downloaded, un-moved
    /// build correctly reads as *not* installed.
    nonisolated static func isInstalledInApplications(_ bundleURL: URL) -> Bool {
        bundleURL.path(percentEncoded: false).hasPrefix("/Applications/")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingVMPaths.append(
            contentsOf:
                urls
                .filter(VMStorageService.isBundleURL)
                .map { $0.path(percentEncoded: false) })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dev builds never auto-register the login agent (issue #451): a
        // worktree/DerivedData/Downloads copy that registered would pin launchd's
        // BTM record to a path that later gets deleted, bricking every future
        // summon. Release auto-registers only from `/Applications`. So the
        // register step is gated behind the pure decision below; the launcher
        // only ever *reads* status until that decision says to register.
        #if DEBUG
        let isReleaseBuild = false
        #else
        let isReleaseBuild = true
        #endif
        let isInApplications = Self.isInstalledInApplications(Bundle.main.bundleURL)

        var status = KernovaBackgroundAgent.currentStatus()
        var action = Self.launcherAction(
            isReleaseBuild: isReleaseBuild, isInApplications: isInApplications, status: status)

        // The only auto-registration path: a Release build in `/Applications`
        // with no agent yet. Register once, then re-evaluate on the new status
        // (`.enabled` → summon, `.requiresApproval` → prompt, or a failure below).
        if action == .register {
            status = KernovaBackgroundAgent.register()
            action = Self.launcherAction(
                isReleaseBuild: isReleaseBuild, isInApplications: isInApplications, status: status)
        }

        switch action {
        case .summon:
            summonAgentGUI(vmPaths: pendingVMPaths)
        case .promptApproval:
            // A disabled login item can't host `…xpc`, so summoning would
            // hang. Surface it and stop — do not masquerade as the service host.
            Self.logger.warning("Agent requires approval; prompting to open Login Items & Extensions")
            presentApprovalNeededAndExit(hadPendingVMs: !pendingVMPaths.isEmpty)
        case .reportUnregisteredDebug:
            Self.logger.warning("Debug build with no registered agent — surfacing the escape hatches")
            presentUnregisteredAgentDebugAndExit(hadPendingVMs: !pendingVMPaths.isEmpty)
        case .reportNotInApplications:
            Self.logger.warning("Release build outside /Applications — refusing to self-register")
            presentMoveToApplicationsAndExit(hadPendingVMs: !pendingVMPaths.isEmpty)
        case .register:
            // register() ran but status is still unusable (it threw for a reason
            // other than a user-disabled item). Nothing to summon — fail loudly
            // rather than hang on a wedged summon.
            Self.logger.error("Agent registration did not take effect; cannot summon")
            Self.exitLauncher(1)
        }
    }

    /// Asks the resident agent to import any forwarded `.kernova` bundles and
    /// show its GUI over its `…xpc` service.
    ///
    /// An empty `vmPaths` is a plain summon (the Login-Items/relaunch trigger).
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

        proxy.summon(vmPaths: vmPaths) {
            Self.logger.notice("Agent acknowledged summon")
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

    /// Debug dead end: no agent is registered and dev builds never auto-register.
    ///
    /// Offers to register *this* copy — the explicit act, equivalent to relaunching
    /// with `--register-agent` — or to quit, and names the `--foreground` /
    /// `--register-agent` escape hatches (issue #451). Only *reached* in Debug
    /// (Release never yields `.reportUnregisteredDebug`).
    private func presentUnregisteredAgentDebugAndExit(hadPendingVMs: Bool) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No Background Agent Registered"
        alert.informativeText =
            hadPendingVMs
            ? "This development build does not automatically register Kernova's login agent, so there is nothing running to open your virtual machine. Register this copy as the login agent, or relaunch with --foreground to run the app directly (no agent) or --register-agent to register without this prompt."
            : "This development build does not automatically register Kernova's login agent, so there is nothing running to open. Register this copy as the login agent, or relaunch with --foreground to run the app directly (no agent) or --register-agent to register without this prompt."
        alert.addButton(withTitle: "Register This Copy")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            registerThisCopyAndContinue()
            return
        }
        Self.exitLauncher(0)
    }

    /// Performs the explicit registration the Debug dead-end button triggers, then
    /// continues by the resulting status: summon on `.enabled`, deep-link Login
    /// Items on `.requiresApproval`, or exit non-zero on an unexpected failure.
    private func registerThisCopyAndContinue() {
        let status = KernovaBackgroundAgent.register()
        switch status {
        case .enabled:
            summonAgentGUI(vmPaths: pendingVMPaths)
        case .requiresApproval:
            presentApprovalNeededAndExit(hadPendingVMs: !pendingVMPaths.isEmpty)
        default:
            Self.logger.error(
                "Register This Copy did not enable the agent (status=\(String(describing: status), privacy: .public))")
            Self.exitLauncher(1)
        }
    }

    /// Release dead end: this copy is not in `/Applications`.
    ///
    /// The launcher refuses to self-register a stray copy (it would pin launchd's
    /// BTM record to a path that may later move or be deleted, issue #451), so it
    /// points the user at the fix and exits.
    private func presentMoveToApplicationsAndExit(hadPendingVMs: Bool) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Kernova to Applications"
        alert.informativeText =
            hadPendingVMs
            ? "Kernova needs to run from your Applications folder. Move Kernova to Applications, then open your virtual machine again."
            : "Kernova needs to run from your Applications folder. Move Kernova to Applications, then open it again."
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
        Self.exitLauncher(0)
    }

    // `nonisolated` so the off-main XPC closures can terminate the launcher.
    nonisolated private static func exitLauncher(_ code: Int32) -> Never {
        exit(code)
    }
}
