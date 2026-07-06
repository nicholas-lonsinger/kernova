import Foundation
import ServiceManagement
import os

/// The registration operations `LoginItemService` needs, abstracted so tests can
/// inject a fake in place of the real `SMAppService.mainApp` (mirrors the
/// injectable-`UserDefaults` seam in `AppPreferences`).
protocol LoginItemRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// Production backend over `SMAppService.mainApp` — registers the app *itself* to
/// open at login (not a helper `.loginItem` bundle, because the VM runs
/// in-process so the background process has to be the full app).
struct MainAppLoginItemRegistration: LoginItemRegistration {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Thin "Open at Login" wrapper over `SMAppService.mainApp` (#460), driving the
/// General settings toggle.
///
/// `.status` is the source of truth and is **never persisted locally** — the
/// toggle reads it live (and refreshes on window re-focus) so a change made in
/// System Settings is always reflected. Defaults OFF (App Store expects opt-in).
struct LoginItemService {
    private let registration: LoginItemRegistration

    /// The process-wide instance over the real `SMAppService.mainApp`.
    @MainActor static let shared = LoginItemService()

    init(registration: LoginItemRegistration = MainAppLoginItemRegistration()) {
        self.registration = registration
    }

    private static let logger = Logger(subsystem: "app.kernova", category: "LoginItem")

    /// The live registration status — the source of truth.
    var status: SMAppService.Status { registration.status }

    /// `true` iff the app is registered and enabled to open at login.
    var isEnabled: Bool { registration.status == .enabled }

    /// Registers or unregisters the app as a login item, returning the resulting
    /// status.
    ///
    /// `.status` (not the result of `register()`) is authoritative: when the user
    /// has disabled the login item in System Settings, `register()` *throws* while
    /// `status` still reports `.requiresApproval`. So the throw is logged and the
    /// fresh status returned; the caller deep-links Settings on `.requiresApproval`.
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

    /// Opens System Settings → General → Login Items & Extensions so the user can
    /// approve a `.requiresApproval` item.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
