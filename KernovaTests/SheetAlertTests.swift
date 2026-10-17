import AppKit
import Testing

@testable import Kernova
@testable import KernovaCore

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

    @Test("first-button response fires buttons[0].action")
    func firstButtonResponse() {
        var fired: [Int] = []
        let buttons = [
            AlertButton("Zero", action: { fired.append(0) }),
            AlertButton("One", action: { fired.append(1) }),
            AlertButton("Two", action: { fired.append(2) }),
        ]
        dispatchAction(for: .alertFirstButtonReturn, buttons: buttons)
        #expect(fired == [0])
    }

    @Test("second-button response fires buttons[1].action")
    func secondButtonResponse() {
        var fired: [Int] = []
        let buttons = [
            AlertButton("Zero", action: { fired.append(0) }),
            AlertButton("One", action: { fired.append(1) }),
            AlertButton("Two", action: { fired.append(2) }),
        ]
        dispatchAction(for: .alertSecondButtonReturn, buttons: buttons)
        #expect(fired == [1])
    }

    @Test("third-button response fires buttons[2].action")
    func thirdButtonResponse() {
        var fired: [Int] = []
        let buttons = [
            AlertButton("Zero", action: { fired.append(0) }),
            AlertButton("One", action: { fired.append(1) }),
            AlertButton("Two", action: { fired.append(2) }),
        ]
        dispatchAction(for: .alertThirdButtonReturn, buttons: buttons)
        #expect(fired == [2])
    }

    @Test("a response naming no button is a no-op")
    func outOfRangeResponseNoOp() {
        var fired = false
        let buttons = [AlertButton("Only", action: { fired = true })]
        // .alertSecondButtonReturn requested but only one button → skip
        dispatchAction(for: .alertSecondButtonReturn, buttons: buttons)
        #expect(!fired)
    }

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

    @Test("A sheet alert carries the accessory view it was given")
    func sheetAlertKeepsItsAccessoryView() {
        let hint = NSView()
        let sheet = SheetAlert(
            .acknowledgement(title: "Couldn't Install", message: "Run it yourself."), accessoryView: hint)

        #expect(sheet.accessoryView === hint)
        #expect(sheet.buttons.map(\.title) == ["OK"])
    }

    // MARK: - initialFirstResponder

    @Test("An alert that asks for nothing names no first responder")
    func aTextOnlyAlertNamesNoFirstResponder() {
        let sheet = SheetAlert(.acknowledgement(title: "Error", message: "It failed."))

        #expect(sheet.initialFirstResponder == nil)
    }

    @Test("An alert with something to fill in names the control the typing lands in")
    func anEditableAlertNamesItsField() {
        let field = NSSecureTextField()
        let sheet = SheetAlert(
            AlertConfiguration(
                title: "Enter the Password", message: "It is needed again.",
                buttons: [AlertButton("OK", role: .default)]),
            accessoryView: field, initialFirstResponder: field)

        #expect(sheet.initialFirstResponder === field)
    }
}
