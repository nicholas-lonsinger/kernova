import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// Unit tests for `AppWindowRegistry.isUntrackedUserPanel(level:styleMask:standing:)`
/// — the pure classifier `hasUserWindow` uses to count AppKit-owned top-level
/// panels (the standard About panel) that the registry doesn't otherwise track,
/// so the Dock icon isn't stripped while one is the last window on screen.
@Suite("AppWindowRegistry.isUntrackedUserPanel", .caseScoped)
struct AppWindowRegistryUntrackedPanelTests {
    @Test("A status-bar-level window does not count, regardless of visibility")
    func statusBarLevelWindow() {
        let onScreen = WindowStanding(isVisible: true, isMiniaturized: false, isOnActiveSpace: true)

        #expect(
            !AppWindowRegistry.isUntrackedUserPanel(
                level: .statusBar, styleMask: [.titled, .closable], standing: onScreen))
    }
}
