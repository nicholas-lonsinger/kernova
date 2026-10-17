import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// Covers ``AppTerminationController/isQuitEvent(_:)`` — which Apple event the
/// gate reads as a quit.
@Suite("AppTerminationController.isQuitEvent", .caseScoped)
struct AppTerminationQuitEventTests {
    /// An Apple event of `eventClass`/`eventID`, as one arrives.
    private func makeEvent(_ eventClass: AEEventClass, _ eventID: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass, eventID: eventID,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
    }

    @Test("Only the Standard Suite's quit is read as one")
    func onlyAQuitEventIsAQuit() {
        #expect(AppTerminationController.isQuitEvent(makeEvent(kCoreEventClass, kAEQuitApplication)))
        #expect(!AppTerminationController.isQuitEvent(makeEvent(kCoreEventClass, kAEOpenApplication)))
        #expect(!AppTerminationController.isQuitEvent(makeEvent(kAEMiscStandards, kAEQuitApplication)))
    }
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
