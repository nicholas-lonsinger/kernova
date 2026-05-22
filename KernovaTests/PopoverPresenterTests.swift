import Testing
import AppKit
@testable import Kernova

/// `PopoverPresenter` exposes a thin lifecycle API around `NSPopover`.
///
/// We do not exercise full popover presentation in unit tests because
/// `NSPopover.show(relativeTo:of:preferredEdge:)` depends on an active key
/// window and a real run loop — neither is reliably available under
/// `xcodebuild test` headless execution. Manual verification of presentation
/// timing belongs to integration testing of the call sites in the detail
/// pane.
@Suite("PopoverPresenter Tests")
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

    @Test("onClose can be assigned and cleared")
    func onCloseAssignable() {
        let presenter = PopoverPresenter()
        var callCount = 0
        presenter.onClose = { callCount += 1 }
        // Drop the closure — verify there's no enforced lifecycle.
        presenter.onClose = nil
        #expect(callCount == 0)
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
}
