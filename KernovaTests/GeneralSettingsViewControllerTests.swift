import AppKit
import KernovaTestSupport
import ServiceManagement
import Testing

@testable import Kernova

/// Behavior tests for the General settings pane's login-item approval note.
@Suite("General Settings Tests", .serialized, .caseScoped)
@MainActor
struct GeneralSettingsViewControllerTests {
    /// A registration whose status the test sets directly.
    private final class StubRegistration: LoginItemRegistration {
        var status: SMAppService.Status

        init(status: SMAppService.Status) { self.status = status }

        func register() throws {}
        func unregister() throws {}
    }

    private static let approvalText = "Needs approval in System Settings › General › Login Items."

    private func makeController(registration: StubRegistration) -> GeneralSettingsViewController {
        let controller = GeneralSettingsViewController(
            loginItem: LoginItemService(registration: registration),
            viewModel: makeLibraryViewModel(preferences: makeTestPreferences()))
        _ = controller.view
        controller.viewWillAppear()
        return controller
    }

    private func approvalNote(in controller: GeneralSettingsViewController) -> NSTextField? {
        allSubviews(NSTextField.self, in: controller.view) {
            !$0.isHidden && $0.stringValue == Self.approvalText
        }.first
    }

    @Test(
        "The approval note shows only while the login item requires approval",
        arguments: [
            (SMAppService.Status.requiresApproval, true),
            (.enabled, false),
            (.notRegistered, false),
            (.notFound, false),
        ])
    func approvalNoteFollowsStatus(status: SMAppService.Status, shown: Bool) {
        let controller = makeController(registration: StubRegistration(status: status))
        defer { controller.viewDidDisappear() }

        #expect((approvalNote(in: controller) != nil) == shown)
    }

    @Test("Returning to the app re-reads the status into the note")
    func activationRefreshesNote() async {
        let registration = StubRegistration(status: .requiresApproval)
        let controller = makeController(registration: registration)
        defer { controller.viewDidDisappear() }
        #expect(approvalNote(in: controller) != nil)

        // Approving in System Settings, then switching back to Kernova.
        registration.status = .enabled
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        // The pane observes on the main queue, so its refresh may be queued there.
        await drainMainQueue()

        #expect(approvalNote(in: controller) == nil)
    }
}
