import Foundation
import ServiceManagement
import os

/// The registration operations `LoginItemService` needs, abstracted so tests can
/// inject a fake in place of the real `SMAppService`.
protocol LoginItemRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// Registers the bootstrap helper embedded at `Contents/Library/LoginItems`,
/// which opens the app through Launch Services carrying
/// `LaunchPosture.loginLaunchFlag` and then exits.
///
/// The registered service is deliberately *not* the app: `SMAppService`
/// documents `unregister` as killing a running registered service, and scopes
/// its re-register-after-update requirement to LaunchAgents and LaunchDaemons —
/// both of which would land on the VM-hosting process if it were registered
/// itself (#801).
struct LoginHelperRegistration: LoginItemRegistration {
    /// The helper's bundle identifier, which is what
    /// `SMAppService.loginItem(identifier:)` resolves against the bundles in
    /// `Contents/Library/LoginItems`.
    static let helperBundleIdentifier = "app.kernova.loginhelper"

    private var service: SMAppService { .loginItem(identifier: Self.helperBundleIdentifier) }

    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

/// "Launch into Background at Login" wrapper over `SMAppService`, driving the
/// General settings toggle.
///
/// `.status` is the source of truth and is **never persisted locally** — the
/// toggle reads it live, so a change made in System Settings is always
/// reflected.
struct LoginItemService {
    private let registration: LoginItemRegistration

    /// The process-wide instance over the real `SMAppService` registration.
    @MainActor static let shared = LoginItemService()

    init(registration: LoginItemRegistration = LoginHelperRegistration()) {
        self.registration = registration
    }

    private static let logger = Logger(subsystem: "app.kernova", category: "LoginItem")

    /// The live registration status. `.notFound` means the helper is missing
    /// from the running bundle.
    var status: SMAppService.Status { registration.status }

    var isEnabled: Bool { registration.status == .enabled }

    /// Registers or unregisters the app as a login item, returning the resulting
    /// status.
    ///
    /// The returned `.status`, not the outcome of `register()`, is authoritative:
    /// with the item disabled in System Settings, `register()` throws while
    /// `status` reports `.requiresApproval`, which the caller deep-links on.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> SMAppService.Status {
        do {
            if enabled { try registration.register() } else { try registration.unregister() }
        } catch {
            Self.logger.error(
                "\(enabled ? "register" : "unregister", privacy: .public)() threw: \(error.localizedDescription, privacy: .public)"
            )
        }
        let status = registration.status
        Self.logger.notice(
            "Login item \(enabled ? "enable" : "disable", privacy: .public) → status=\(String(describing: status), privacy: .public)"
        )
        return status
    }

    /// Opens System Settings → General → Login Items & Extensions.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
