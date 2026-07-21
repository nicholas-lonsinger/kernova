import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.appMenuQuitItems(isTestHost:keepInMenuBar:)` — the
/// pure helper that decides the app menu's quit section so every mode presents an
/// *honest* command (#624).
///
/// Covers all four `(isTestHost, keepInMenuBar)` combinations. The three
/// presentations: resident + preference on → the split "Close All Windows" (⌘Q)
/// and "Quit Kernova" (⌥⌘Q); the test host or resident + preference off → a single
/// "Quit Kernova" (⌘Q) that really quits.
@Suite("AppDelegate.appMenuQuitItems")
struct AppDelegateQuitMenuTests {
    /// The single-item presentation shared by the test host and the resident app
    /// with the preference off: one "Quit Kernova" ⌘Q routed through the gate.
    private func expectSingleTrueQuit(_ items: [AppDelegate.AppMenuQuitItem]) {
        #expect(items.count == 1)
        let item = items.first
        #expect(item?.title == "Quit Kernova")
        #expect(item?.keyEquivalent == "q")
        #expect(item?.usesOptionModifier == false)
        #expect(item?.action == .terminateThroughGate)
    }

    @Test("Resident app with keep-in-menu-bar on shows the honest split")
    func residentKeepOn() {
        let items = AppDelegate.appMenuQuitItems(isTestHost: false, keepInMenuBar: true)
        #expect(items.count == 2)

        // "Close All Windows" ⌘Q — the soft quit that downgrades to a GUI close.
        #expect(items.first?.title == "Close All Windows")
        #expect(items.first?.keyEquivalent == "q")
        #expect(items.first?.usesOptionModifier == false)
        #expect(items.first?.action == .terminateThroughGate)

        // "Quit Kernova" ⌥⌘Q — the true quit that bypasses the downgrade.
        #expect(items.last?.title == "Quit Kernova")
        #expect(items.last?.keyEquivalent == "q")
        #expect(items.last?.usesOptionModifier == true)
        #expect(items.last?.action == .quitCompletely)
    }

    @Test("Resident app with keep-in-menu-bar off shows a single quit that terminates")
    func residentKeepOff() {
        expectSingleTrueQuit(
            AppDelegate.appMenuQuitItems(isTestHost: false, keepInMenuBar: false))
    }

    @Test("Test host shows a single standard quit regardless of the preference (on)")
    func testHostPreferenceOn() {
        expectSingleTrueQuit(
            AppDelegate.appMenuQuitItems(isTestHost: true, keepInMenuBar: true))
    }

    @Test("Test host shows a single standard quit regardless of the preference (off)")
    func testHostPreferenceOff() {
        expectSingleTrueQuit(
            AppDelegate.appMenuQuitItems(isTestHost: true, keepInMenuBar: false))
    }
}
