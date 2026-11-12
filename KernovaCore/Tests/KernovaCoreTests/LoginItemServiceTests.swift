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
    /// Configurable fake: records calls, optionally throws, and flips `status` to
    /// mimic `SMAppService` on a successful register/unregister.
    private final class FakeRegistration: LoginItemRegistration {
        var status: SMAppService.Status
        var registerCount = 0
        var unregisterCount = 0
        var registerError: Error?
        var unregisterError: Error?

        init(status: SMAppService.Status) { self.status = status }

        func register() throws {
            registerCount += 1
            if let registerError { throw registerError }
            status = .enabled
        }

        func unregister() throws {
            unregisterCount += 1
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    private struct FakeError: Error {}

    @Test("isEnabled reflects the backend .enabled status")
    func isEnabledReflectsStatus() {
        #expect(LoginItemService(registration: FakeRegistration(status: .enabled)).isEnabled)
        #expect(!LoginItemService(registration: FakeRegistration(status: .notRegistered)).isEnabled)
        #expect(!LoginItemService(registration: FakeRegistration(status: .requiresApproval)).isEnabled)
    }

    @Test("an unregister() throw is swallowed and the live status is returned")
    func unregisterThrowReturnsLiveStatus() {
        let fake = FakeRegistration(status: .enabled)
        fake.unregisterError = FakeError()
        let service = LoginItemService(registration: fake)

        let status = service.setEnabled(false)

        #expect(fake.unregisterCount == 1)
        // The throw left the fake's status untouched at .enabled.
        #expect(status == .enabled)
    }

    @Test("the shipping registration is the main app, not an agent")
    func defaultRegistrationIsMainApp() {
        // The protocol seam hides which service is wired, so nothing else catches
        // a regression to `.agent(plistName:)` — whose `unregister` would kill the
        // running app (#801). Reads status only; never registers.
        #expect(LoginItemService().status == SMAppService.mainApp.status)
    }
}
