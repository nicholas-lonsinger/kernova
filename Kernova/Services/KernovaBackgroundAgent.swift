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
    /// status (or `nil` if registration threw).
    ///
    /// `register()` is idempotent and returns without throwing even when the item
    /// still needs the user's approval in System Settings (status
    /// `.requiresApproval`) — there is no `.disabled` case; a user-disabled login
    /// item reports `.requiresApproval`. Callers inspect the status to decide
    /// whether to deep-link Settings.
    @discardableResult
    static func registerIfNeeded() -> SMAppService.Status? {
        let service = service
        // Already enabled (the common case for a re-run launcher) — nothing to do.
        if service.status == .enabled { return .enabled }
        do {
            try service.register()
            let status = service.status
            switch status {
            case .enabled:
                logger.notice("Background agent registered and enabled")
            case .requiresApproval:
                logger.warning(
                    "Background agent registered but needs approval in Login Items & Extensions")
            default:
                logger.notice(
                    "Background agent registered (status=\(String(describing: status), privacy: .public))"
                )
            }
            return status
        } catch {
            logger.error(
                "Failed to register background agent: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Opens System Settings → General → Login Items & Extensions so the user can
    /// re-enable a disabled agent.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
