import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// `presentSheetAlert(_:in:didDismiss:completion:)` can't be unit-tested directly.
///
/// `NSAlert.beginSheetModal(for:)` requires a real window + run loop. The
/// two pure helpers it delegates to (`configureNSAlertButton` and
/// `dispatchAction(for:buttons:)`) are testable in isolation and carry
/// the logic worth verifying.
@Suite("SheetAlert Tests", .caseScoped)
@MainActor
struct SheetAlertTests {
    // MARK: - configureNSAlertButton

    @Test(".default role wires the Return key")
    func defaultRoleReturnsReturn() {
        let button = NSButton()
        configureNSAlertButton(button, role: .default)
        #expect(button.keyEquivalent == "\r")
        #expect(!button.hasDestructiveAction)
    }

    @Test(".cancel role wires the Escape key")
    func cancelRoleWiresEscape() {
        let button = NSButton()
        configureNSAlertButton(button, role: .cancel)
        #expect(button.keyEquivalent == "\u{1B}")
        #expect(!button.hasDestructiveAction)
    }

    @Test(".destructive role clears the key equivalent and sets destructive tint")
    func destructiveRoleTints() {
        let button = NSButton()
        configureNSAlertButton(button, role: .destructive)
        #expect(button.keyEquivalent.isEmpty)
        #expect(button.hasDestructiveAction)
    }

    @Test(".standard role clears the key equivalent and leaves tint default")
    func standardRoleIsPlain() {
        let button = NSButton()
        configureNSAlertButton(button, role: .standard)
        #expect(button.keyEquivalent.isEmpty)
        #expect(!button.hasDestructiveAction)
    }

    // MARK: - dispatchAction

    @Test("a response naming no button runs no action, cancel included")
    func outOfRangeResponseRunsNothing() {
        var fired: [String] = []
        let buttons = [
            AlertButton("Go", role: .default, action: { fired.append("go") }),
            AlertButton("Stop", role: .cancel, action: { fired.append("stop") }),
        ]

        // Nothing was chosen, so nothing the user chose runs. An alert whose
        // answer something is waiting on gets it from whatever ended the sheet
        // — `AppAlertPresenter` for a closing window — not from a reading of a response
        // code this has no way to check.
        dispatchAction(for: .stop, buttons: buttons)

        #expect(fired.isEmpty)
    }
}
