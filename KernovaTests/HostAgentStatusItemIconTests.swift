import AppKit
import Testing

@testable import KernovaUI

/// Unit tests for `HostAgentStatusItemController.iconSymbol(hasUndoneStarts:hasWaitingAlerts:)`
/// — which glyph the menu-bar item wears.
///
/// Every name is resolved against the running system: a name the symbol set
/// does not carry leaves the headless app with no visible status item, and it is
/// the only affordance such a process has.
@Suite("HostAgentStatusItemController.iconSymbol", .caseScoped)
@MainActor
struct HostAgentStatusItemIconTests {
    @Test("A quiet status item wears the plain window glyph")
    func quietGlyph() {
        let symbol = HostAgentStatusItemController.iconSymbol(hasUndoneStarts: false, hasWaitingAlerts: false)

        #expect(symbol == "macwindow")
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
    }

    @Test("A start left undone with no window to report it swaps in the badged glyph")
    func undoneStartGlyph() {
        let symbol = HostAgentStatusItemController.iconSymbol(hasUndoneStarts: true, hasWaitingAlerts: false)

        #expect(symbol == "display.trianglebadge.exclamationmark")
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        // An undone start outranks any other waiting alert.
        #expect(
            HostAgentStatusItemController.iconSymbol(hasUndoneStarts: true, hasWaitingAlerts: true)
                == symbol)
    }

    @Test("Another alert with no window to show it swaps in its own glyph")
    func waitingAlertGlyph() {
        let symbol = HostAgentStatusItemController.iconSymbol(hasUndoneStarts: false, hasWaitingAlerts: true)

        #expect(symbol == "exclamationmark.bubble")
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
    }
}
