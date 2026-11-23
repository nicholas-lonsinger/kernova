import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// Covers ``AppTerminationController/isQuitEvent(_:)`` — which Apple event the
/// gate reads as a quit.
@Suite("AppTerminationController.isQuitEvent", .caseScoped)
struct AppTerminationQuitEventTests {
}

/// Covers the one place the gate's answer becomes the reply AppKit acts on.
@Suite("NSApplication.TerminateReply from the gate's reply", .caseScoped)
struct AppTerminationReplyTests {
    @Test(
        "Each gate reply becomes the AppKit reply of the same meaning",
        arguments: [
            (AppTerminationController.TerminationReply.cancel, NSApplication.TerminateReply.terminateCancel),
            (.now, .terminateNow),
            (.later, .terminateLater),
        ])
    func mapsEachReply(
        reply: AppTerminationController.TerminationReply, expected: NSApplication.TerminateReply
    ) {
        #expect(NSApplication.TerminateReply(reply) == expected)
    }
}
