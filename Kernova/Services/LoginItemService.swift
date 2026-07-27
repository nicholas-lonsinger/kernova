import Foundation
import ServiceManagement
import os

/// The registration operations `LoginItemService` needs, abstracted so tests can
/// inject a fake in place of the real `SMAppService.mainApp`.
protocol LoginItemRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// Registers the app *itself* to open at login, not a helper `.loginItem`
/// bundle — the VM runs in-process, so the background process must be the app.
struct MainAppLoginItemRegistration: LoginItemRegistration {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// "Open at Login" wrapper over `SMAppService.mainApp`, driving the General
/// settings toggle.
///
/// `.status` is the source of truth and is **never persisted locally** — the
/// toggle reads it live, so a change made in System Settings is always
/// reflected.
struct LoginItemService {
    private let registration: LoginItemRegistration

    /// The process-wide instance over the real `SMAppService.mainApp`.
    @MainActor static let shared = LoginItemService()

    init(registration: LoginItemRegistration = MainAppLoginItemRegistration()) {
        self.registration = registration
    }

    private static let logger = Logger(subsystem: "app.kernova", category: "LoginItem")

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
