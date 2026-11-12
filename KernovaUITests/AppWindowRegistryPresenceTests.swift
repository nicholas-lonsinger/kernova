import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers `AppWindowRegistry.hasUserWindow` — the window-presence answer the
/// activation-policy reconcile and the reopen leg both read — the clipboard
/// window's close-driven deregistration, and the `WindowResidencyHosting` call a
/// presentation owes.
@Suite("AppWindowRegistry presence", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct AppWindowRegistryPresenceTests {
    private let preferences = makeTestPreferences()

    /// Records the residency calls the registry makes, standing in for the
    /// controller that answers them in the resident app.
    private final class StubResidencyHost: WindowResidencyHosting {
        var prepareCount = 0
        var syncCount = 0
        var guiPosture = GUIPosture.foreground

        func prepareToPresentWindow() { prepareCount += 1 }
        func syncActivationPolicy() { syncCount += 1 }
    }

    private func makeRegistry(focus: RecordingSessionFocus = RecordingSessionFocus()) -> AppWindowRegistry {
        makeWindowRegistry(makeLibraryViewModel(preferences: preferences), focus: focus)
    }

    @Test("An untracked titled panel on the stage counts as a user window")
    func untrackedPanelCounts() {
        let registry = makeRegistry()
        showTestWindow(styleMask: [.titled, .closable])

        #expect(!registry.hasTrackedUserWindow)
        #expect(registry.hasUserWindow)
    }

    @Test("A miniaturized library window counts")
    func libraryMiniaturized() async throws {
        let registry = makeRegistry()
        registry.showLibrary(bringToFront: true)
        let window = try #require(registry.libraryWindow)

        // AppKit reports the miniaturize a runloop turn later — the window is
        // still `isVisible` when `miniaturize(_:)` returns — so the wait is
        // driven by the notification that reports it.
        let gate = AsyncGate()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { _ in gate.notify() }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.miniaturize(nil)
        try await gate.wait { window.isMiniaturized && !window.isVisible }

        #expect(registry.hasTrackedUserWindow)
    }

    @Test("The Settings window counts on its own")
    func settingsShown() throws {
        let registry = makeRegistry()
        registry.showSettings()

        #expect(registry.hasTrackedUserWindow)
    }

    @Test("An automatic config check shows its window without bringing Kernova forward; the user's does both")
    func configCheckActivatesOnlyForTheUser() throws {
        let focus = RecordingSessionFocus()
        let registry = makeRegistry(focus: focus)

        registry.showConfigCheck(.automatic)
        let window = try #require(registry.configCheckWindow)
        #expect(window.isVisible)
        #expect(focus.requests.isEmpty)

        registry.showConfigCheck(.user)
        #expect(window.isVisible)
        #expect(focus.requests == [.activate])
    }
}
