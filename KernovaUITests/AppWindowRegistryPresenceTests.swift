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
    func libraryMiniaturized() throws {
        let focus = RecordingSessionFocus()
        let registry = makeRegistry(focus: focus)
        registry.showLibrary(bringToFront: true)
        let window = try #require(registry.libraryWindow)

        focus.miniaturize(window)

        #expect(registry.hasTrackedUserWindow)
    }

    @Test("The Settings window brings Kernova forward and counts on its own")
    func settingsShown() throws {
        let focus = RecordingSessionFocus()
        let registry = makeRegistry(focus: focus)
        registry.showSettings()

        let window = try #require(registry.settingsWindow)
        #expect(focus.requests == [.activate, .present(window, .keyAndFront)])
        #expect(registry.hasTrackedUserWindow)
    }

    @Test("An automatic config check shows its window without bringing Kernova forward; the user's does both")
    func configCheckActivatesOnlyForTheUser() throws {
        let focus = RecordingSessionFocus()
        let registry = makeRegistry(focus: focus)

        registry.showConfigCheck(.automatic)
        let window = try #require(registry.configCheckWindow)
        #expect(focus.requests == [.present(window, .front)])

        registry.showConfigCheck(.user)
        #expect(focus.requests == [.present(window, .front), .activate, .present(window, .keyAndFront)])
    }
}
