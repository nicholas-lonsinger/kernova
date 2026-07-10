import AppKit
import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.isUntrackedUserPanel(_:)` — the pure classifier
/// `hasVisibleUserWindow` uses to count AppKit-owned top-level panels (the standard
/// About panel) that the app doesn't otherwise track, so the Dock icon isn't
/// stripped while one is the last window on screen.
///
/// Regression coverage for #437: closing a tracked auxiliary window (a display or
/// clipboard window) while only the About panel remains visible must not drop the
/// resident agent to `.accessory`.
@Suite("AppDelegate.isUntrackedUserPanel", .serialized)
@MainActor
struct AppDelegateUntrackedPanelTests {
    @Test("A visible, titled, normal-level window counts as an untracked user panel")
    func titledNormalLevelWindow() {
        let window = makeTestWindow(styleMask: [.titled, .closable])
        defer { window.close() }
        window.orderFront(nil)

        #expect(AppDelegate.isUntrackedUserPanel(window))
    }

    @Test("A status-bar-level window does not count, regardless of visibility")
    func statusBarLevelWindow() {
        let window = makeTestWindow(styleMask: [.titled, .closable])
        defer { window.close() }
        window.level = .statusBar
        window.orderFront(nil)

        #expect(!AppDelegate.isUntrackedUserPanel(window))
    }

    @Test("A visible borderless window does not count")
    func borderlessWindow() {
        let window = makeTestWindow(styleMask: [.borderless])
        defer { window.close() }
        window.orderFront(nil)

        #expect(!AppDelegate.isUntrackedUserPanel(window))
    }

    @Test("A titled, normal-level window that was never shown does not count")
    func neverShownWindow() {
        let window = makeTestWindow(styleMask: [.titled, .closable])
        defer { window.close() }

        #expect(!AppDelegate.isUntrackedUserPanel(window))
    }
}
