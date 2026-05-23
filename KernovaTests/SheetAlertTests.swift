import Testing
import AppKit
@testable import Kernova

/// `presentSheetAlert(_:in:completion:)` can't be unit-tested directly.
///
/// `NSAlert.beginSheetModal(for:)` requires a real window + run loop. The
/// two pure helpers it delegates to (`configureNSAlertButton` and
/// `dispatchAction(for:buttons:)`) are testable in isolation and carry
/// the logic worth verifying.
@Suite("SheetAlert Tests")
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

    @Test("out-of-range response is a no-op")
    func outOfRangeResponseNoOp() {
        var fired = false
        let buttons = [AlertButton("Only", action: { fired = true })]
        // .alertSecondButtonReturn requested but only one button → skip
        dispatchAction(for: .alertSecondButtonReturn, buttons: buttons)
        #expect(!fired)
    }

    // MARK: - AlertConfiguration shape

    @Test("AlertConfiguration preserves button order and roles")
    func configurationOrderAndRoles() {
        let config = AlertConfiguration(
            title: "Test",
            message: "body",
            buttons: [
                AlertButton("One", role: .destructive),
                AlertButton("Two", role: .default),
                AlertButton("Three", role: .cancel),
            ]
        )
        #expect(config.buttons.count == 3)
        #expect(config.buttons[0].title == "One")
        #expect(config.buttons[0].role == .destructive)
        #expect(config.buttons[1].role == .default)
        #expect(config.buttons[2].role == .cancel)
    }

    @Test("AlertButton init defaults to .standard role and a no-op action")
    func alertButtonDefaults() {
        let button = AlertButton("Plain")
        #expect(button.role == .standard)
        // Action is no-op; just verify calling it doesn't crash.
        button.action()
    }
}
