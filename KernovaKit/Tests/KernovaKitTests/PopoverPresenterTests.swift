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

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Content in a window, standing in for a popover's, with the window's content
    /// view left for anything outside it: first responder needs neither key status
    /// nor presentation.
    private func makeContent() -> (content: NSViewController, window: NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let content = NSViewController()
        content.view = NSView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(content.view)
        return (content, window)
    }

    @MainActor
    private final class FieldWatcher: NSObject, NSTextFieldDelegate {
        var refusesToEnd = false
        private(set) var endedEdits = 0

        func control(_: NSControl, textShouldEndEditing _: NSText) -> Bool { !refusesToEnd }
        func controlTextDidEndEditing(_: Notification) { endedEdits += 1 }
    }

    /// A window with a field under edit, typed into so its delegate is asked before
    /// the edit ends, beside an anchor inside `surroundings`.
    private func makeEdit(
        anchorIn surroundings: NSView
    ) throws -> (window: NSWindow, anchor: NSView, field: NSTextField, watcher: FieldWatcher) {
        let frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: true)
        let anchor = NSView()
        surroundings.addSubview(anchor)
        window.contentView?.addSubview(surroundings)
        let watcher = FieldWatcher()
        let field = NSTextField(string: "name")
        field.delegate = watcher
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("d", replacementRange: NSRange(location: 0, length: 0))
        return (window, anchor, field, watcher)
    }

    @Test("a field's edit ends, with the keyboard going to what surrounds the anchor")
    func endsAnEditForTheViewAroundTheAnchor() throws {
        let surroundings = FocusableView()
        let edit = try makeEdit(anchorIn: surroundings)

        PopoverPresenter().endTextEdit(around: edit.anchor, behavior: .transient)

        #expect(edit.watcher.endedEdits == 1)
        #expect(edit.field.currentEditor() == nil)
        #expect(edit.window.firstResponder === surroundings)
    }

    @Test("with nothing around the anchor to take it, nothing holds the keyboard")
    func endsAnEditWithNothingAroundTheAnchor() throws {
        let edit = try makeEdit(anchorIn: NSView())

        PopoverPresenter().endTextEdit(around: edit.anchor, behavior: .transient)

        #expect(edit.watcher.endedEdits == 1)
        #expect(edit.window.firstResponder === edit.window)
    }

    @Test("a field that refuses to end its edit keeps the keyboard")
    func aFieldRefusingToEndKeepsTheKeyboard() throws {
        let edit = try makeEdit(anchorIn: FocusableView())
        edit.watcher.refusesToEnd = true
        let editor = edit.window.firstResponder

        PopoverPresenter().endTextEdit(around: edit.anchor, behavior: .transient)

        #expect(edit.watcher.endedEdits == 0)
        #expect(edit.window.firstResponder === editor)
    }

    @Test("a popover that comes up on its own leaves an edit alone")
    func applicationDefinedLeavesAnEditAlone() throws {
        let edit = try makeEdit(anchorIn: FocusableView())
        let editor = edit.window.firstResponder

        PopoverPresenter().endTextEdit(around: edit.anchor, behavior: .applicationDefined)

        #expect(edit.watcher.endedEdits == 0)
        #expect(edit.window.firstResponder === editor)
    }

    @Test("a text view is no field: it stays first responder to be returned to")
    func leavesATextViewAlone() {
        let (content, window) = makeContent()
        let textView = NSTextView()
        window.contentView?.addSubview(textView)
        #expect(window.makeFirstResponder(textView))

        PopoverPresenter().endTextEdit(around: content.view, behavior: .transient)

        #expect(window.firstResponder === textView)
    }

    @Test("content with nothing that takes the keyboard has it held for it")
    func holdsTheKeyboardForContentWithoutAFocusableView() throws {
        let (content, window) = makeContent()

        PopoverPresenter().takeKeyboard(for: content, behavior: .transient)

        let focused = try #require(window.firstResponder as? NSView)
        #expect(focused.isDescendant(of: content.view))
    }

    @Test("a view in the content that took the keyboard keeps it")
    func leavesTheKeyboardWithAFocusedView() {
        let (content, window) = makeContent()
        let focusable = FocusableView()
        content.view.addSubview(focusable)
        #expect(window.makeFirstResponder(focusable))

        PopoverPresenter().takeKeyboard(for: content, behavior: .transient)

        #expect(window.firstResponder === focusable)
    }

    @Test("a view outside the content gives up the keyboard")
    func takesTheKeyboardFromAViewOutsideTheContent() throws {
        let (content, window) = makeContent()
        let elsewhere = FocusableView()
        window.contentView?.addSubview(elsewhere)
        #expect(window.makeFirstResponder(elsewhere))

        PopoverPresenter().takeKeyboard(for: content, behavior: .transient)

        let focused = try #require(window.firstResponder as? NSView)
        #expect(focused.isDescendant(of: content.view))
    }

    @Test("a field in the content that took the keyboard keeps it")
    func leavesTheKeyboardWithAFieldInTheContent() throws {
        let (content, window) = makeContent()
        let field = NSTextField(string: "note")
        content.view.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSText)

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
