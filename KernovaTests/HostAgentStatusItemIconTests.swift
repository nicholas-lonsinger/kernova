import AppKit
import Testing

@testable import Kernova

/// Unit tests for `HostAgentStatusItemController.iconSymbol(hasUndoneStarts:)`
/// — which glyph the menu-bar item wears.
///
/// Both names are resolved against the running system: a name the symbol set
/// does not carry leaves the headless app with no visible status item, and it is
/// the only affordance such a process has.
@Suite("HostAgentStatusItemController.iconSymbol", .caseScoped)
@MainActor
struct HostAgentStatusItemIconTests {
    @Test("A quiet status item wears the plain window glyph")
    func quietGlyph() {
        let symbol = HostAgentStatusItemController.iconSymbol(hasUndoneStarts: false)

        #expect(symbol == "macwindow")
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
    }

    @Test("A start left undone with no window to report it swaps in the badged glyph")
    func undoneStartGlyph() {
        let symbol = HostAgentStatusItemController.iconSymbol(hasUndoneStarts: true)

        #expect(symbol == "display.trianglebadge.exclamationmark")
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
    }
}
