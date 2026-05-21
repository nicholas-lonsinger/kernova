import Testing
import AppKit
@testable import Kernova

@Suite("AlertPresenter Tests")
@MainActor
struct AlertPresenterTests {
    @Test("buttonIndex maps first-button response to 0")
    func firstButton() {
        let index = AlertPresenter.buttonIndex(
            for: .alertFirstButtonReturn,
            count: 3
        )
        #expect(index == 0)
    }

    @Test("buttonIndex maps second-button response to 1")
    func secondButton() {
        let index = AlertPresenter.buttonIndex(
            for: .alertSecondButtonReturn,
            count: 3
        )
        #expect(index == 1)
    }

    @Test("buttonIndex maps third-button response to 2")
    func thirdButton() {
        let index = AlertPresenter.buttonIndex(
            for: .alertThirdButtonReturn,
            count: 3
        )
        #expect(index == 2)
    }

    @Test("buttonIndex clamps responses below the button range to 0")
    func clampLow() {
        let weird = NSApplication.ModalResponse(rawValue: -42)
        let index = AlertPresenter.buttonIndex(for: weird, count: 3)
        #expect(index == 0)
    }

    @Test("buttonIndex clamps responses above the button range to last")
    func clampHigh() {
        let beyondLast = NSApplication.ModalResponse(
            rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 99
        )
        let index = AlertPresenter.buttonIndex(for: beyondLast, count: 3)
        #expect(index == 2)
    }

    @Test("buttonIndex returns 0 when count is zero")
    func zeroCount() {
        let index = AlertPresenter.buttonIndex(
            for: .alertFirstButtonReturn,
            count: 0
        )
        #expect(index == 0)
    }

    @Test("AlertButton.ok defaults to OK and .default role")
    func okDefault() {
        let button = AlertButton.ok()
        #expect(button.title == "OK")
        #expect(button.role == .default)
    }

    @Test("AlertButton.cancel defaults to Cancel and .cancel role")
    func cancelDefault() {
        let button = AlertButton.cancel()
        #expect(button.title == "Cancel")
        #expect(button.role == .cancel)
    }

    @Test("AlertButton.destructive forwards the title and sets .destructive role")
    func destructiveRole() {
        let button = AlertButton.destructive("Move to Trash")
        #expect(button.title == "Move to Trash")
        #expect(button.role == .destructive)
    }

    @Test("AlertButton.plain has the .plain role with no key equivalent")
    func plainRole() {
        let button = AlertButton.plain("Skip")
        #expect(button.title == "Skip")
        #expect(button.role == .plain)
    }
}
