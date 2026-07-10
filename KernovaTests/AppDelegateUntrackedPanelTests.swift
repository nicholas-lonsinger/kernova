import AppKit
import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.isUntrackedUserPanel(_:)` — the pure classifier
/// `hasVisibleUserWindow` uses to count AppKit-owned top-level panels (the standard
/// About panel, the toolbar customization palette) that the app doesn't otherwise
/// track, so the Dock icon isn't stripped while one is the last window on screen.
///
/// Regression coverage for #437: closing a tracked auxiliary window (a display or
/// clipboard window) while only the About panel remains visible must not drop the
/// resident agent to `.accessory`.
@Suite("AppDelegate.isUntrackedUserPanel", .serialized)
@MainActor
struct AppDelegateUntrackedPanelTests {
    /// Builds a plain window with `isReleasedWhenClosed` disarmed.
    ///
    /// The default `true` double-releases an ARC-owned `NSWindow` on `close()`
    /// (see `SettingsWindowController`'s own `isReleasedWhenClosed = false` for
    /// the same reason) — fatal under ARC.
    private static func makeWindow(styleMask: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("A visible, titled, normal-level window counts as an untracked user panel")
    func titledNormalLevelWindow() {
        let window = Self.makeWindow(styleMask: [.titled, .closable])
        defer { window.close() }
        window.orderFront(nil)

        #expect(AppDelegate.isUntrackedUserPanel(window))
    }

    @Test("A status-bar-level window does not count, regardless of visibility")
    func statusBarLevelWindow() {
        let window = Self.makeWindow(styleMask: [.titled, .closable])
        defer { window.close() }
        window.level = .statusBar
        window.orderFront(nil)

        #expect(!AppDelegate.isUntrackedUserPanel(window))
    }

    @Test("A visible borderless window does not count")
    func borderlessWindow() {
        let window = Self.makeWindow(styleMask: [.borderless])
        defer { window.close() }
        window.orderFront(nil)

        #expect(!AppDelegate.isUntrackedUserPanel(window))
    }

    @Test("A titled, normal-level window that was never shown does not count")
    func neverShownWindow() {
        let window = Self.makeWindow(styleMask: [.titled, .closable])
        defer { window.close() }

        #expect(!AppDelegate.isUntrackedUserPanel(window))
    }
}
