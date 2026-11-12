import KernovaTestSupport
import Testing

@testable import KernovaKit
@testable import KernovaTransferProgress

@Suite("ClipboardTransferGesture", .caseScoped)
struct ClipboardTransferGestureTests {
    @Test("every gesture someone waits on outranks every gesture they can leave")
    func awaitedGesturesOutrankTheRest() {
        let every: [ClipboardTransferGesture] = [
            .paste, .preview, .copy, .forward, .send, .drop, .dragOut,
        ]
        for gesture in every where gesture.isAwaited {
            for other in every where !other.isAwaited {
                #expect(
                    gesture.readoutRank > other.readoutRank,
                    "\(gesture) is waited on, so it outranks \(other)")
            }
        }
        // Files dragged out are missing where they were dropped the same way.
        #expect(ClipboardTransferGesture.dragOut.isAwaited)
        #expect(
            ClipboardTransferGesture.dragOut.readoutRank
                == ClipboardTransferGesture.drop.readoutRank)
    }
}
