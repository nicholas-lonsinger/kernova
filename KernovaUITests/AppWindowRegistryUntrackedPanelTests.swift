import AppKit
import Testing

@testable import KernovaUI

/// Unit tests for `AppWindowRegistry.isUntrackedUserPanel(_:)` — the pure
/// classifier `hasUserWindow` uses to count AppKit-owned top-level panels (the
/// standard About panel) that the registry doesn't otherwise track, so the Dock
/// icon isn't stripped while one is the last window on screen.
///
/// Regression coverage for #437: closing a tracked auxiliary window (a display
/// window) while only the About panel remains visible must not drop the
/// resident agent to `.accessory`.
@Suite("AppWindowRegistry.isUntrackedUserPanel", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct AppWindowRegistryUntrackedPanelTests {
    @Test("A status-bar-level window does not count, regardless of visibility")
    func statusBarLevelWindow() {
        let window = makeTestWindow(styleMask: [.titled, .closable])
        window.level = .statusBar
        window.orderFront(nil)

        #expect(!AppWindowRegistry.isUntrackedUserPanel(window))
    }
}
