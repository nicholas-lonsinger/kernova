import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The one derivation of how each flow's offers behave: which flow the channel
/// and the sending end name, and the frames each flow speaks.
@Suite("ClipboardOfferDiscipline", .caseScoped)
struct ClipboardOfferDisciplineTests {
    @Test("the channel and the sending end name the flow, and the drop channel carries none guest→host")
    func flowBySender() {
        #expect(ClipboardOfferDiscipline(kind: .clipboard, sender: .host)?.flow == .clipboard)
        #expect(ClipboardOfferDiscipline(kind: .clipboard, sender: .guest)?.flow == .clipboard)
        #expect(ClipboardOfferDiscipline(kind: .drop, sender: .host)?.flow == .drop)
        #expect(ClipboardOfferDiscipline(kind: .drop, sender: .guest) == nil)
        #expect(ClipboardOfferDiscipline(kind: .drop, receiver: .host) == nil)
    }

    @Test("each flow offers and releases in its own vocabulary")
    func vocabulary() throws {
        let clipboard = try #require(ClipboardOfferDiscipline(kind: .clipboard, sender: .guest))
        let drop = try #require(ClipboardOfferDiscipline(kind: .drop, sender: .host))

        func offer(_ discipline: ClipboardOfferDiscipline) -> Frame.OneOf_Payload? {
            discipline.offerFrame(generation: 1, reps: [], isConcealed: false).payload
        }
        guard case .clipboardOffer = offer(clipboard),
            case .dropOffer = offer(drop),
            case .clipboardRelease = clipboard.releaseFrame(generation: 1).payload,
            case .dropRelease = drop.releaseFrame(generation: 1).payload
        else {
            Issue.record("A flow spoke another flow's vocabulary")
            return
        }
    }

    @Test("only a drop is up front and on a claim deadline")
    func readoutsAndDeadlines() throws {
        let clipboard = try #require(ClipboardOfferDiscipline(kind: .clipboard, sender: .host))
        let drop = try #require(ClipboardOfferDiscipline(kind: .drop, sender: .host))

        #expect(clipboard.readout == .sharedPeerPaste)
        #expect(drop.readout == .upFront)
        #expect(drop.hasClaimDeadline && !clipboard.hasClaimDeadline)
        #expect(clipboard.supersedes && !drop.supersedes)
    }
}
