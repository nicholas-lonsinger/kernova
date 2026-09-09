import AppKit
import KernovaKit
import Testing

@testable import Kernova

/// `presentSheetAlert(_:in:completion:)` can't be unit-tested directly.
///
/// `NSAlert.beginSheetModal(for:)` requires a real window + run loop. The
/// two pure helpers it delegates to (`configureNSAlertButton` and
/// `dispatchAction(for:buttons:)`) are testable in isolation and carry
/// the logic worth verifying.
@Suite("SheetAlert Tests", .admissionGated)
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

    // MARK: - init(confirming:)

    /// A confirmation whose confirm destroys something and whose alternative is
    /// the gentler route — the force-stop shape.
    private func destructiveConfirmPrompt() -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .forceStop, title: "Force Stop \u{201C}VM\u{201D}?",
            message: "Unsaved guest state is lost.",
            confirmTitle: "Force Stop", dismissTitle: "Cancel",
            alternatives: [ConfirmationAlternative(title: "Shut Down", disposition: .graceful)])
    }

    /// The inverse — the stop-paused shape, whose confirm is the gentle route.
    private func safeConfirmPrompt() -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .stopPaused, title: "Stop \u{201C}VM\u{201D}?",
            message: "Resume it first, or terminate it.",
            confirmTitle: "Resume and Shut Down", confirmIsDestructive: false,
            dismissTitle: "Cancel",
            alternatives: [
                ConfirmationAlternative(title: "Force Stop", isDestructive: true, disposition: .force)
            ])
    }

    @Test("A destructive confirm puts its safe alternative on Return and itself last")
    func confirmingDestructiveWithSafeAlternative() {
        let config = AlertConfiguration(
            confirming: destructiveConfirmPrompt(), confirm: {}, alternative: { _ in })

        #expect(config.buttons.map(\.title) == ["Shut Down", "Cancel", "Force Stop"])
        #expect(config.buttons.map(\.role) == [.default, .cancel, .destructive])
    }

    @Test("A safe confirm keeps Return and its destructive alternative comes last")
    func confirmingSafeWithDestructiveAlternative() {
        let config = AlertConfiguration(
            confirming: safeConfirmPrompt(), confirm: {}, alternative: { _ in })

        #expect(config.buttons.map(\.title) == ["Resume and Shut Down", "Cancel", "Force Stop"])
        #expect(config.buttons.map(\.role) == [.default, .cancel, .destructive])
    }

    @Test("A destructive confirm with no alternative leads, and no button takes Return")
    func confirmingDestructiveAlone() {
        let prompt = ConfirmationPrompt(
            kind: .deleteSnapshot, title: "Delete \u{201C}Before\u{201D}?",
            message: "Its files go to the Trash.", confirmTitle: "Delete", dismissTitle: "Cancel")

        let config = AlertConfiguration(confirming: prompt, confirm: {})

        #expect(config.buttons.map(\.title) == ["Delete", "Cancel"])
        #expect(config.buttons.map(\.role) == [.destructive, .cancel])
        #expect(!config.buttons.contains { $0.role == .default })
    }

    @Test("A safe confirm with no alternative takes Return")
    func confirmingSafeAlone() {
        let prompt = ConfirmationPrompt(
            kind: .enableClipboardPassthrough, title: "Turn On?", message: "The guest reads it.",
            confirmTitle: "Turn On", confirmIsDestructive: false, dismissTitle: "Cancel")

        let config = AlertConfiguration(confirming: prompt, confirm: {})

        #expect(config.buttons.map(\.title) == ["Turn On", "Cancel"])
        #expect(config.buttons.map(\.role) == [.default, .cancel])
    }

    @Test("Each button reaches its own handler, alternatives carrying which one was picked")
    func confirmingRoutesEachButton() {
        var confirmed = 0
        var dismissed = 0
        var chosen: [ConfirmationAlternative] = []
        let prompt = destructiveConfirmPrompt()
        let config = AlertConfiguration(
            confirming: prompt,
            confirm: { confirmed += 1 },
            alternative: { chosen.append($0) },
            dismiss: { dismissed += 1 })

        for button in config.buttons { button.action() }

        #expect(confirmed == 1)
        #expect(dismissed == 1)
        #expect(chosen == prompt.alternatives)
    }

    @Test("Titles and copy come from the prompt")
    func confirmingTakesItsWordsFromThePrompt() {
        let prompt = destructiveConfirmPrompt()
        let config = AlertConfiguration(confirming: prompt, confirm: {}, alternative: { _ in })

        #expect(config.title == prompt.title)
        #expect(config.message == prompt.message)
        #expect(config.accessoryView == nil)
    }

    // MARK: - acknowledgement

    @Test("An acknowledgement is one OK button on Return")
    func acknowledgementIsASingleDefaultOK() {
        let config = AlertConfiguration.acknowledgement(title: "Error", message: "It failed.")

        #expect(config.title == "Error")
        #expect(config.message == "It failed.")
        #expect(config.buttons.map(\.title) == ["OK"])
        #expect(config.buttons.map(\.role) == [.default])
        #expect(config.accessoryView == nil)
    }

    @Test("An acknowledgement carries the accessory view it was given")
    func acknowledgementKeepsItsAccessoryView() {
        let hint = NSView()
        let config = AlertConfiguration.acknowledgement(
            title: "Couldn't Install", message: "Run it yourself.", accessoryView: hint)

        #expect(config.accessoryView === hint)
    }
}
