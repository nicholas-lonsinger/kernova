import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ClipboardTransferGesture", .caseScoped)
struct ClipboardTransferGestureTests {
    @Test("only a refusal of a gesture made here interrupts on this side")
    func onlyPeerPasteIsTheirsToReport() {
        for gesture in [
            ClipboardTransferGesture.paste, .preview, .copy, .forward, .drop,
        ] {
            #expect(gesture.isMadeHere, "\(gesture) refuses a gesture made on this side")
        }
        // The guest user's own paste refusal — their agent's dropdown reveals it
        // over there.
        #expect(!ClipboardTransferGesture.peerPaste.isMadeHere)
    }

    @Test("every gesture someone waits on outranks every gesture they can leave")
    func awaitedGesturesOutrankTheRest() {
        let every: [ClipboardTransferGesture] = [
            .paste, .peerPaste, .preview, .copy, .forward, .drop, .dragOut,
        ]
        for gesture in every where gesture.isAwaited {
            for other in every where !other.isAwaited {
                #expect(
                    gesture.readoutRank > other.readoutRank,
                    "\(gesture) is waited on, so it outranks \(other)")
            }
        }
        // The paste holds the app it is pasting into; the drop's files are only
        // missing from the guest until it lands.
        #expect(
            ClipboardTransferGesture.peerPaste.readoutRank
                > ClipboardTransferGesture.drop.readoutRank)
        // Files dragged out are missing where they were dropped the same way.
        #expect(ClipboardTransferGesture.dragOut.isAwaited)
        #expect(
            ClipboardTransferGesture.dragOut.readoutRank
                == ClipboardTransferGesture.drop.readoutRank)
    }
}
