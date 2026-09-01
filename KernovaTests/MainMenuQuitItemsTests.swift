import Testing

@testable import Kernova

/// Unit tests for `MainMenuController.appMenuQuitItems(isTestHost:keepInMenuBar:)` — the
/// pure helper that decides the app menu's quit section so every mode presents an
/// *honest* command (#624).
@Suite("MainMenuController.appMenuQuitItems", .admissionGated)
struct MainMenuQuitItemsTests {
    /// The single-item presentation shared by the test host and the resident app
    /// with the preference off: one "Quit Kernova" ⌘Q routed through the gate.
    private func expectSingleTrueQuit(_ items: [MainMenuController.AppMenuQuitItem]) {
        #expect(items.count == 1)
        let item = items.first
        #expect(item?.title == "Quit Kernova")
        #expect(item?.keyEquivalent == "q")
        #expect(item?.usesOptionModifier == false)
        #expect(item?.action == .terminateThroughGate)
    }

    @Test("Resident app with keep-in-menu-bar on shows the honest split")
    func residentKeepOn() {
        let items = MainMenuController.appMenuQuitItems(isTestHost: false, keepInMenuBar: true)
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
            MainMenuController.appMenuQuitItems(isTestHost: false, keepInMenuBar: false))
    }

    @Test("Test host shows a single standard quit regardless of the preference (on)")
    func testHostPreferenceOn() {
        expectSingleTrueQuit(
            MainMenuController.appMenuQuitItems(isTestHost: true, keepInMenuBar: true))
    }

    @Test("Test host shows a single standard quit regardless of the preference (off)")
    func testHostPreferenceOff() {
        expectSingleTrueQuit(
            MainMenuController.appMenuQuitItems(isTestHost: true, keepInMenuBar: false))
    }
}
