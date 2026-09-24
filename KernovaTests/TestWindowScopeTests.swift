import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers the scope `.scopedWindows` opens around a test case: what closing it
/// leaves on screen, and the failure a window made outside one records.
///
/// Each test opens its own scope and closes it before asserting, standing in for
/// the trait's teardown at the end of a case.
@Suite("TestWindowScope", .serialized, .admissionGated)
@MainActor
struct TestWindowScopeTests {
    /// What the alerts under test were answered with.
    private final class Answers {
        var dismissals = 0
        var clicks = 0
    }

    private func alert(answering answers: Answers) -> AlertConfiguration {
        AlertConfiguration(
            title: "Scoped", message: "An alert on a scoped window.",
            buttons: [AlertButton("OK", role: .default, action: { answers.clicks += 1 })])
    }

    private func present(_ config: AlertConfiguration, in window: NSWindow, answers: Answers)
        -> NSAlert
    {
        presentSheetAlert(config, in: window, didDismiss: { answers.dismissals += 1 })
    }

    @Test("Closing a scope takes every window it holds off screen")
    func closeOrdersEveryWindowOut() {
        let scope = TestWindowScope()
        let (made, shown, hosting, adopted) = ScopedWindowsTrait.$scope.withValue(scope) {
            let made = makeTestWindow(styleMask: [.titled])
            let shown = showTestWindow(styleMask: [.titled])
            let hosting = showInTestWindow(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80)))
            let content = NSViewController()
            content.view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
            let adopted = NSWindow.withStableContentSize(
                NSSize(width: 120, height: 80), styleMask: [.titled],
                contentViewController: content)
            adopted.orderFront(nil)
            adoptAppWindow(adopted)
            return (made, shown, hosting, adopted)
        }
        #expect([shown, hosting, adopted].allSatisfy { $0.isVisible })

        scope.close()

        #expect([made, shown, hosting, adopted].allSatisfy { !$0.isVisible })
        #expect(!adopted.isReleasedWhenClosed)
    }

    @Test("Closing a scope ends a window's sheets, the one queued behind included, answering neither")
    func closeEndsQueuedSheets() {
        let scope = TestWindowScope()
        let window = ScopedWindowsTrait.$scope.withValue(scope) {
            showTestWindow(styleMask: [.titled])
        }
        let answers = Answers()
        let first = present(alert(answering: answers), in: window, answers: answers)
        let second = present(alert(answering: answers), in: window, answers: answers)
        #expect(window.sheets.count == 2)

        scope.close()

        #expect(window.sheets.isEmpty)
        #expect(!first.window.isVisible)
        #expect(!second.window.isVisible)
        #expect(answers.dismissals == 2)
        #expect(answers.clicks == 0)
    }

    @Test("An adopted sheet is ended on its parent before it closes")
    func adoptedSheetEndsOnItsParent() {
        let scope = TestWindowScope()
        let answers = Answers()
        let (parent, sheet) = ScopedWindowsTrait.$scope.withValue(scope) {
            let parent = showTestWindow(styleMask: [.titled])
            let sheet = present(alert(answering: answers), in: parent, answers: answers).window
            adoptAppWindow(sheet)
            return (parent, sheet)
        }

        scope.close()

        #expect(parent.sheets.isEmpty)
        #expect(sheet.sheetParent == nil)
        #expect(!sheet.isVisible)
        #expect(answers.dismissals == 1)
        #expect(answers.clicks == 0)
    }

    @Test("A window made outside a scope fails the test that made it")
    func unscopedWindowRecordsAnIssue() {
        ScopedWindowsTrait.$scope.withValue(nil) {
            withKnownIssue {
                _ = makeTestWindow(styleMask: [.titled])
            }
        }
    }
}
