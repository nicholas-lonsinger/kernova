import Testing

@testable import Kernova

/// Unit tests for `MainMenuController.appMenuQuitItems(downgradesQuitToGUIClose:)` —
/// the pure helper that decides the app menu's quit section so every mode
/// presents an *honest* command (#624).
@Suite("MainMenuController.appMenuQuitItems", .admissionGated)
struct MainMenuQuitItemsTests {
    /// The single-item presentation every process whose ⌘Q really quits gets:
    /// one "Quit Kernova" ⌘Q routed through the gate.
    private func expectSingleTrueQuit(_ items: [MainMenuController.AppMenuQuitItem]) {
        #expect(items.count == 1)
        let item = items.first
        #expect(item?.title == "Quit Kernova")
        #expect(item?.keyEquivalent == "q")
        #expect(item?.usesOptionModifier == false)
        #expect(item?.action == .terminateThroughGate)
    }

    @Test("A quit that downgrades to a GUI close shows the honest split")
    func downgradedQuitSplits() {
        let items = MainMenuController.appMenuQuitItems(downgradesQuitToGUIClose: true)
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

    @Test("A quit that really quits shows one item that says so")
    func trueQuitIsSingleItem() {
        expectSingleTrueQuit(
            MainMenuController.appMenuQuitItems(downgradesQuitToGUIClose: false))
    }
}
