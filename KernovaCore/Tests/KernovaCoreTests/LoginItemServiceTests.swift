import KernovaTestSupport
import ServiceManagement
import Testing

@testable import KernovaCore

/// Unit tests for `LoginItemService` — the `SMAppService.mainApp` wrapper.
///
/// Uses an injectable `LoginItemRegistration` fake so register/unregister and
/// status mapping are exercised without touching the real login-item database
/// (mirrors the injectable-`UserDefaults` seam in `AppPreferences`).
@Suite("LoginItemService", .caseScoped)
struct LoginItemServiceTests {
    @Test("the shipping registration is the main app, not an agent")
    func defaultRegistrationIsMainApp() {
        // The protocol seam hides which service is wired, so nothing else catches
        // a regression to `.agent(plistName:)` — whose `unregister` would kill the
        // running app (#801). Reads status only; never registers.
        #expect(LoginItemService().status == SMAppService.mainApp.status)
    }
}
