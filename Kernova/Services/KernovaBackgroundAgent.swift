import Foundation
import KernovaKit
import ServiceManagement
import os

/// Registers the main Kernova app as a launchd-managed launch-at-login agent and
/// reports its enablement.
///
/// Wraps `SMAppService.agent` over the bundled
/// `Contents/Library/LaunchAgents/app.kernova.plist`, which declares `RunAtLoad`,
/// `LimitLoadToSessionType = Aqua`, and `MachServices = { …xpc }` and runs
/// the app's own executable with `--background`. Registration is unconditional on
/// first launch ("always on once installed"); the user can still disable it in
/// System Settings → General → Login Items & Extensions.
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

    /// Registers the agent if it isn't already enabled, returning the resulting
    /// status.
    ///
    /// `status` (not the result of `register()`) is the source of truth: when the
    /// user has **disabled** the login item in System Settings, `register()`
    /// *throws* "Operation not permitted" while `status` still reports
    /// `.requiresApproval` (verified on-device — there is no `.disabled` case).
    /// So this attempts registration, then reads and returns `status` regardless
    /// of throw, and the launcher deep-links Settings on `.requiresApproval`.
    @discardableResult
    static func registerIfNeeded() -> SMAppService.Status {
        let service = service
        // Already enabled (the common case for a re-run launcher) — nothing to do.
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
