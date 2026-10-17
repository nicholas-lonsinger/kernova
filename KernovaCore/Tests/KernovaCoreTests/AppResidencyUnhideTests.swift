import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Covers the unhide decision —
/// ``AppResidencyPolicy/unhideOutcome(hasVisibleUserWindow:keepInMenuBar:)``. ⌘H turns
/// every window's `isVisible` false without closing one, so a background close
/// landing mid-hide is only legible once the app is back on screen, and the
/// unhide is what makes it legible.
///
/// No arm of it terminates: unhiding is a person asking for the app, so a
/// window that closed mid-hide is answered by making the app reachable rather
/// than by quitting under them.
@Suite("AppResidencyPolicy unhide", .caseScoped)
struct AppResidencyUnhideTests {
    @Test("windows that survived the hide keep the Dock icon", arguments: [true, false])
    func windowOnScreenShowsDockIcon(keepInMenuBar: Bool) {
        #expect(
            AppResidencyPolicy.unhideOutcome(
                hasVisibleUserWindow: true, keepInMenuBar: keepInMenuBar) == .showDockIcon)
    }

    @Test("a close that landed mid-hide drops to the status item when it exists")
    func noWindowWithKeepOnGoesHeadless() {
        #expect(
            AppResidencyPolicy.unhideOutcome(
                hasVisibleUserWindow: false, keepInMenuBar: true) == .goHeadless)
    }

    @Test("a close that landed mid-hide shows the library when there is no status item")
    func noWindowWithKeepOffPresentsLibrary() {
        // Never `.quit`: the person unhiding just asked for the app, and with
        // the toggle off a headless app has no status item to be reached
        // through — the close is answered by putting the library back.
        #expect(
            AppResidencyPolicy.unhideOutcome(
                hasVisibleUserWindow: false, keepInMenuBar: false) == .presentLibrary)
    }
}
