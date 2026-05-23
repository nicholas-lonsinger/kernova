import Testing
import AppKit
@testable import Kernova

/// `SheetPresenter` exposes a thin lifecycle API around `NSWindow.beginSheet`.
///
/// We do not exercise full sheet presentation in unit tests because
/// `beginSheet(_:completionHandler:)` depends on a real run loop and a
/// parent window with active key state — neither is reliably available
/// under headless `xcodebuild test` execution. Manual verification of
/// presentation timing belongs to integration testing of the call sites.
@Suite("SheetPresenter Tests")
@MainActor
struct SheetPresenterTests {
    @Test("isShown is false before show")
    func notShownInitially() {
        let presenter = SheetPresenter()
        #expect(!presenter.isShown)
    }

    @Test("close before show is idempotent")
    func closeBeforeShowIsIdempotent() {
        let presenter = SheetPresenter()
        presenter.close()
        presenter.close()
        #expect(!presenter.isShown)
    }

    @Test("onClose can be assigned and cleared")
    func onCloseAssignable() {
        let presenter = SheetPresenter()
        var callCount = 0
        presenter.onClose = { callCount += 1 }
        presenter.onClose = nil
        #expect(callCount == 0)
    }
}
