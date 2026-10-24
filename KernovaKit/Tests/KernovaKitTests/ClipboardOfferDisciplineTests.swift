import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The one derivation of how each flow's offers behave: which flow the channel
/// and the sending end name, and the frames each flow speaks.
@Suite("ClipboardOfferDiscipline", .caseScoped)
struct ClipboardOfferDisciplineTests {
    @Test("the channel and the sending end name the flow")
    func flowBySender() {
        #expect(ClipboardOfferDiscipline(kind: .clipboard, sender: .host).flow == .clipboard)
        #expect(ClipboardOfferDiscipline(kind: .clipboard, sender: .guest).flow == .clipboard)
        #expect(ClipboardOfferDiscipline(kind: .drop, sender: .host).flow == .drop)
        #expect(ClipboardOfferDiscipline(kind: .drop, sender: .guest).flow == .dragOut)
    }

    @Test("each flow offers and releases in its own vocabulary")
    func vocabulary() {
        let clipboard = ClipboardOfferDiscipline(kind: .clipboard, sender: .guest)
        let drop = ClipboardOfferDiscipline(kind: .drop, sender: .host)
        let drag = ClipboardOfferDiscipline(kind: .drop, sender: .guest)

        guard case .clipboardOffer = clipboard.offerFrame(generation: 1, reps: [], isConcealed: false).payload,
            case .dropOffer = drop.offerFrame(generation: 1, reps: [], isConcealed: false).payload,
            case .dragOffer = drag.offerFrame(generation: 1, reps: [], isConcealed: false).payload,
            case .clipboardRelease = clipboard.releaseFrame(generation: 1).payload,
            case .dropRelease = drop.releaseFrame(generation: 1).payload,
            case .dragRelease = drag.releaseFrame(generation: 1).payload
        else {
            Issue.record("A flow spoke another flow's vocabulary")
            return
        }
    }

    @Test("only a drop is up front and on a claim deadline; a drag out opens its readout per offer")
    func readoutsAndDeadlines() {
        let clipboard = ClipboardOfferDiscipline(kind: .clipboard, sender: .host)
        let drop = ClipboardOfferDiscipline(kind: .drop, sender: .host)
        let drag = ClipboardOfferDiscipline(kind: .drop, sender: .guest)

        #expect(clipboard.readout == .sharedPeerPaste)
        #expect(drop.readout == .upFront)
        #expect(drag.readout == .perEntryOnFirstRequest)
        #expect(drag.servingGesture == .dragOut)
        #expect(drop.hasClaimDeadline && !drag.hasClaimDeadline && !clipboard.hasClaimDeadline)
        #expect(clipboard.supersedes && !drop.supersedes && !drag.supersedes)
        #expect(drag.ownerWithdraws && !drop.ownerWithdraws && !clipboard.ownerWithdraws)
    }

    @Test("only a drag out's staging outlives the newest-generations window, until its take discards it")
    func stagingRetention() {
        let newest = ClipboardFileStaging.Retention.newest(ClipboardFileStaging.maxGenerations)

        #expect(ClipboardOfferDiscipline(kind: .clipboard, receiver: .host).stagingRetention == newest)
        #expect(ClipboardOfferDiscipline(kind: .clipboard, receiver: .guest).stagingRetention == newest)
        #expect(ClipboardOfferDiscipline(kind: .drop, receiver: .guest).stagingRetention == newest)
        #expect(
            ClipboardOfferDiscipline(kind: .drop, receiver: .host).stagingRetention
                == .untilDiscarded)
    }
}
