import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// Covers the scope `.scopedWindows` opens around a test case: that closing it
/// ends a window's sheets.
///
/// The test opens its own scope and closes it before asserting, standing in for
/// the trait's teardown at the end of a case.
@Suite("TestWindowScope", .serialized, .caseScoped)
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
}
