import Foundation
import KernovaKit
import ServiceManagement
import os

/// Wraps the `SMAppService.agent` operations that register the main Kernova app
/// as a launchd-managed launch-at-login agent and report its enablement.
///
/// Wraps `SMAppService.agent` over the bundled
/// `Contents/Library/LaunchAgents/app.kernova.plist`, which declares `RunAtLoad`,
/// `LimitLoadToSessionType = Aqua`, and `MachServices = { …xpc }` and runs
/// the app's own executable with `--background`.
///
/// This type performs the SMAppService operations but does **not** decide *when*
/// to register — that policy (Debug never auto-registers; Release auto-registers
/// only from `/Applications`; the explicit `--register-agent` flag / "Register
/// This Copy" button override both gates) lives in `LauncherAppDelegate`
/// (issue #451, prevention of the wrong-copy BTM pin). Call `currentStatus()` to
/// read enablement without side effects, and `register()` for the intentional
/// registration act.
///
/// `SMAppService.agent` is the only API that can declare `MachServices`, and the
/// `BundleProgram` may point at the app's own `Contents/MacOS/Kernova` — being
/// the launchd job's process is what grants the Mach receive right, so no
/// separate helper bundle is needed.
enum KernovaBackgroundAgent {
    private static let logger = Logger(subsystem: "app.kernova", category: "BackgroundAgent")

    private static var service: SMAppService {
        SMAppService.agent(plistName: KernovaHostRelayIdentity.launchAgentPlistName)
    }

    /// The agent's current enablement, read with **no side effect**.
    ///
    /// `.enabled` (registered and running), `.requiresApproval` (registered but
    /// the user disabled it in Login Items — there is no `.disabled` case),
    /// `.notRegistered` (never registered from this bundle path), or `.notFound`.
    /// The launcher reads this to decide whether it may summon, must prompt for
    /// approval, or (Debug) has hit a dead end — without ever registering.
    static func currentStatus() -> SMAppService.Status {
        service.status
    }

    /// Registers the agent (unless it is already enabled) and returns the
    /// resulting status — the intentional-install act.
    ///
    /// `status` (not the result of `register()`) is the source of truth: when the
    /// user has **disabled** the login item in System Settings, `register()`
    /// *throws* "Operation not permitted" while `status` still reports
    /// `.requiresApproval` (verified on-device — there is no `.disabled` case).
    /// So this attempts registration, then reads and returns `status` regardless
    /// of throw, and the caller deep-links Settings on `.requiresApproval`.
    ///
    /// Callers gate *whether* to invoke this (see the type doc); this method
    /// itself always registers when asked, so the explicit `--register-agent` /
    /// "Register This Copy" paths can override the launch-time policy.
    @discardableResult
    static func register() -> SMAppService.Status {
        let service = service
        // Already enabled (a re-run launcher, or a redundant explicit request) —
        // nothing to do.
        if service.status == .enabled { return .enabled }
        do {
            try service.register()
        } catch {
            // A user-disabled login item makes register() throw; `status` below
            // still reflects the real (`.requiresApproval`) state, so just log.
            logger.error(
                "register() threw: \(error.localizedDescription, privacy: .public)")
        }
        let status = service.status
        switch status {
        case .enabled:
            logger.notice("Background agent registered and enabled")
        case .requiresApproval:
            logger.warning("Background agent needs approval in Login Items & Extensions")
        default:
            logger.notice(
                "Background agent status=\(String(describing: status), privacy: .public)")
        }
        return status
    }

    /// Opens System Settings → General → Login Items & Extensions so the user can
    /// re-enable a disabled agent.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
