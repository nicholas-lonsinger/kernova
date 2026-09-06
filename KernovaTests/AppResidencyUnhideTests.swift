import AppKit
import Testing

@testable import Kernova

/// Covers the unhide leg — ``AppResidencyController/unhideOutcome(hasVisibleUserWindow:keepInMenuBar:)``
/// and the ``AppResidencyController/noteDidUnhide()`` that runs it. ⌘H turns
/// every window's `isVisible` false without closing one, so a background close
/// landing mid-hide is only legible once the app is back on screen, and the
/// unhide is what makes it legible.
///
/// No arm of it terminates: unhiding is a person asking for the app, so a
/// window that closed mid-hide is answered by making the app reachable rather
/// than by quitting under them.
@Suite("AppResidencyController unhide", .serialized, .admissionGated)
@MainActor
struct AppResidencyUnhideTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.appresidencyunhide")

    private func makeController() -> AppResidencyController {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        return AppResidencyController(
            viewModel: viewModel,
            preferences: preferences,
            windows: AppWindowRegistry(
                viewModel: viewModel,
                displayPlacement: VMDisplayPlacementController(viewModel: viewModel)))
    }

    // MARK: - The decision

    @Test("windows that survived the hide keep the Dock icon", arguments: [true, false])
    func windowOnScreenShowsDockIcon(keepInMenuBar: Bool) {
        #expect(
            AppResidencyController.unhideOutcome(
                hasVisibleUserWindow: true, keepInMenuBar: keepInMenuBar) == .showDockIcon)
    }

    @Test("a close that landed mid-hide drops to the status item when it exists")
    func noWindowWithKeepOnGoesHeadless() {
        #expect(
            AppResidencyController.unhideOutcome(
                hasVisibleUserWindow: false, keepInMenuBar: true) == .goHeadless)
    }

    @Test("a close that landed mid-hide shows the library when there is no status item")
    func noWindowWithKeepOffPresentsLibrary() {
        // Never `.quit`: the person unhiding just asked for the app, and with
        // the toggle off a headless app has no status item to be reached
        // through — the close is answered by putting the library back.
        #expect(
            AppResidencyController.unhideOutcome(
                hasVisibleUserWindow: false, keepInMenuBar: false) == .presentLibrary)
    }

    // MARK: - The wiring

    @Test("A controller nothing has happened to has scheduled no reconcile")
    func freshControllerSchedulesNothing() {
        #expect(makeController().pendingUnhideReconcileForTesting == nil)
    }

    @Test("Unhiding runs the unhide decision against the live window state")
    func unhideRunsTheDecision() async throws {
        // A window on screen pins the outcome to `.showDockIcon`, whose
        // `setActivationPolicy(.regular)` is a no-op against the already-regular
        // test host — the suite exercises the controller without
        // `start(provenance:)`, for the reason `AppResidencyPresentationTests`
        // gives.
        let window = makeTestWindow(styleMask: [.titled])
        window.orderFront(nil)
        defer { window.close() }
        let controller = makeController()

        controller.noteDidUnhide()

        let reconcile = try #require(controller.pendingUnhideReconcileForTesting)
        #expect(await reconcile.value == .showDockIcon)
    }
}
