import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaAppKitShared

/// `PopoverPresenter` exposes a thin lifecycle API around `NSPopover`.
///
/// We do not exercise full popover presentation in unit tests because
/// `NSPopover.show(relativeTo:of:preferredEdge:)` depends on an active key
/// window and a real run loop — neither is reliably available under
/// `xcodebuild test` headless execution. Manual verification of presentation
/// timing belongs to integration testing of the call sites in the detail
/// pane.
@Suite("PopoverPresenter Tests", .caseScoped)
@MainActor
struct PopoverPresenterTests {
    @Test("isShown is false before show")
    func notShownInitially() {
        let presenter = PopoverPresenter()
        #expect(!presenter.isShown)
    }

    @Test("close before show is idempotent")
    func closeBeforeShowIsIdempotent() {
        let presenter = PopoverPresenter()
        presenter.close()
        presenter.close()
        #expect(!presenter.isShown)
    }

    @Test("popoverDidClose delivery invokes onClose and resets state")
    func popoverDidCloseFiresOnClose() {
        let presenter = PopoverPresenter()
        var callCount = 0
        presenter.onClose = { callCount += 1 }

        // Simulate the delegate hop without showing a real popover.
        // `popoverDidClose` is the delegate method NSPopover invokes when
        // dismissed; calling it directly verifies our delegate forwards to
        // `onClose` and clears the internal popover reference.
        let dummyNotification = Notification(name: NSPopover.didCloseNotification)
        presenter.popoverDidClose(dummyNotification)

        #expect(callCount == 1)
        #expect(!presenter.isShown)
    }

    /// Content in a window, standing in for a popover's: first responder needs
    /// neither key status nor presentation.
    private func makeContent() -> (content: NSViewController, window: NSWindow) {
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        return (content, NSWindow(contentViewController: content))
    }

    @Test("content with nothing that takes the keyboard has it held for it")
    func holdsTheKeyboardForContentWithoutAFocusableView() throws {
        let (content, window) = makeContent()

        PopoverPresenter().takeKeyboard(for: content, behavior: .transient)

        let focused = try #require(window.firstResponder as? NSView)
        #expect(focused.isDescendant(of: content.view))
    }

    @Test("a view in the content that took the keyboard keeps it")
    func leavesTheKeyboardWithAFocusedField() throws {
        let (content, window) = makeContent()
        let field = NSTextField(string: "note")
        content.view.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder)

        PopoverPresenter().takeKeyboard(for: content, behavior: .transient)

        #expect(window.firstResponder === editor)
    }

    @Test("showing the same content again keeps one holder")
    func aSecondTakeReusesTheHolder() {
        let (content, window) = makeContent()
        let presenter = PopoverPresenter()

        presenter.takeKeyboard(for: content, behavior: .transient)
        let holder = window.firstResponder
        #expect(window.makeFirstResponder(nil))
        presenter.takeKeyboard(for: content, behavior: .transient)

        #expect(window.firstResponder === holder)
        #expect(content.view.subviews.count == 1)
    }

    @Test("an application-defined popover leaves the keyboard alone")
    func applicationDefinedLeavesTheKeyboardAlone() {
        let (content, window) = makeContent()
        let before = window.firstResponder

        PopoverPresenter().takeKeyboard(for: content, behavior: .applicationDefined)

        #expect(window.firstResponder === before)
        #expect(content.view.subviews.isEmpty)
    }
}
