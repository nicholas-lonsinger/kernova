import ServiceManagement
import Testing

@testable import Kernova

/// Unit tests for `LoginItemService` — the "Open at Login" wrapper (#460).
///
/// Uses an injectable `LoginItemRegistration` fake so register/unregister and
/// status mapping are exercised without touching the real login-item database
/// (mirrors the injectable-`UserDefaults` seam in `AppPreferences`).
@Suite("LoginItemService")
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

    @Test("setEnabled(true) registers and returns the resulting .enabled status")
    func setEnabledTrueRegisters() {
        let fake = FakeRegistration(status: .notRegistered)
        let service = LoginItemService(registration: fake)

        let status = service.setEnabled(true)

        #expect(fake.registerCount == 1)
        #expect(fake.unregisterCount == 0)
        #expect(status == .enabled)
    }

    @Test("setEnabled(false) unregisters and returns the resulting .notRegistered status")
    func setEnabledFalseUnregisters() {
        let fake = FakeRegistration(status: .enabled)
        let service = LoginItemService(registration: fake)

        let status = service.setEnabled(false)

        #expect(fake.unregisterCount == 1)
        #expect(fake.registerCount == 0)
        #expect(status == .notRegistered)
    }

    @Test("a register() throw is swallowed and the live status is returned")
    func registerThrowReturnsLiveStatus() {
        // Mirrors the real SMAppService behavior: a user-disabled item makes
        // register() throw while status still reports .requiresApproval — the
        // service must surface that status for the caller to deep-link Settings.
        let fake = FakeRegistration(status: .requiresApproval)
        fake.registerError = FakeError()
        let service = LoginItemService(registration: fake)

        let status = service.setEnabled(true)

        #expect(fake.registerCount == 1)
        #expect(status == .requiresApproval)
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

    @Test("status passes through the backend")
    func statusPassesThrough() {
        #expect(LoginItemService(registration: FakeRegistration(status: .notFound)).status == .notFound)
    }
}
