import AppKit
import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaLogging
import KernovaWire

/// Ends a drag the host has taken over by being its destination: a surface
/// over the whole screen under the guest pointer, answering copy so the source
/// keeps its items, and reporting each step of the hand-off on the take.
///
/// The steps go `ARMED` (the surface is up), `TARGETED` (the guest's drag
/// manager entered it with the taken drag, answered copy), then the take's END:
/// `CAUGHT` once the drag ended on it. The host releases the guest's button
/// onto the surface only after `TARGETED`, so anything else arriving before
/// then — the wrong items, a source that forbids a copy — is answered with no
/// operation and refuses the take.
///
/// A drop delivers the drag — the drag's owner calls its promises in and sizes
/// its folders before the take ends — only once the host asked with
/// `DragDeliver`, which the catcher answers `DELIVERING` while it is targeted:
/// the host releases the button for that drop alone, and every other drop on
/// the surface calls nothing in. The ask holds for the showing it came in, as
/// `TARGETED` does: standing the surface down drops it.
///
/// Once `TARGETED` is out the host may already have released the button, and
/// that release is a real drop under the guest pointer, so a refusal after
/// `TARGETED` leaves the surface up until the guest's drag ends, to refuse
/// whatever drops on it. The host calling the take off takes the surface down
/// at once: it calls a take off only before releasing anything onto it, so the
/// user's drag goes on in the guest.
///
/// While the host's Mac session is over this VM's display, the host stands the
/// surface down and moves the guest pointer itself, so the drag can drop
/// inside the guest once `STOOD_DOWN` says the surface is out of the way; the
/// take stays, and the host shows the surface again —
/// a fresh `ARMED`, then `TARGETED` — when the session leaves. Drag callbacks
/// AppKit delivers while the surface is down are refused without a word, and
/// the press ending then is the user's own drop inside the guest, which ends
/// the take `RETURNED`.
///
/// The surface covers the screen and takes mouse events, so while it is up the
/// guest cannot be clicked: every path that shows it ends at ``finish(_:)`` —
/// the drag concluding or ending, a refusal before `TARGETED`, the host
/// calling the take off, the session peer stopping, the press ending while the
/// drag is off the surface, or a click reaching the surface, which no drag in
/// flight lets happen.
@MainActor
final class GuestDragCatcher {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestDragCatcher")

    /// What one guest drag callback shows the catcher.
    struct Drag: Equatable {
        /// The operations the drag's source allows.
        let sourceMask: NSDragOperation
        /// The drag's items under ``GuestDraggedItems``' rule, or `nil` when
        /// it carries anything else.
        let items: [GuestDragItem]?
    }

    /// One stretch of the surface being up for a take, reported by its own
    /// `ARMED`.
    private struct Showing {
        /// The guest's drag manager is inside the surface with the taken drag.
        var entered = false
        /// `TARGETED` went out in this showing, so the host may have released
        /// the button.
        var targeted = false
        /// The host asked for this showing's drop to deliver the drag.
        var delivers = false
    }

    /// The drag a take armed the catcher for.
    private struct Take {
        let claim: GuestDragWatcher.Claim
        let id: DragTakeID
        /// The surface is up for the take; `nil` while the host's Mac session
        /// is over this VM's display.
        var showing: Showing? = Showing()
        /// This side ended the take: the surface stays up only to see the
        /// guest's drag end, refusing any drop on it unless it was caught.
        var ended = false
        /// The drag ended on the surface.
        var caught = false
    }

    private let peer: any GuestDragOutPeer
    private let makeSurface: @MainActor (GuestDragCatcher) -> any GuestDragCatcherSurface
    private var surface: (any GuestDragCatcherSurface)?
    private var take: Take?

    /// Hears each delivering drop: the take it ended, the claim it carried, and
    /// the drop's file promises. It ends the take itself.
    var onDeliver: ((DragTakeID, GuestDragWatcher.Claim, [any FilePromiseReceiving]) -> Void)?

    init(
        peer: any GuestDragOutPeer,
        makeSurface: @escaping @MainActor (GuestDragCatcher) -> any GuestDragCatcherSurface
    ) {
        self.peer = peer
        self.makeSurface = makeSurface
    }

    // MARK: - Takes

    /// Puts the surface up for a drag the watcher has handed to take `id`, and
    /// reports it armed.
    func arm(_ claim: GuestDragWatcher.Claim, take id: DragTakeID) {
        // A take still up for an earlier press ends with its press; this one
        // needs the surface.
        if take != nil { finish(refusing: WireError(.dragNotCurrent, debugDetail: "A newer take replaced it")) }
        let surface = surface ?? makeSurface(self)
        self.surface = surface
        take = Take(claim: claim, id: id)
        guard surface.show(items: claim.items) else {
            return finish(refusing: WireError(.dragNotCurrent, debugDetail: "There is no screen to put the catcher on"))
        }
        peer.answerTake(id, .report(.armed))
        Self.logger.log(.notice, "Catcher armed for the host's take")
    }

    /// The host's Mac session carrying take `id` left this VM's display
    /// (`shown`) or came back over it: shows the surface again and reports it
    /// armed, or stands it down and reports it stood down, keeping the take
    /// either way. A take this side already ended stays as it is.
    func setShown(_ shown: Bool, take id: DragTakeID) {
        guard let current = take, current.id == id, !current.ended else { return }
        guard shown else {
            take?.showing = nil
            surface?.hide()
            peer.answerTake(id, .report(.stoodDown))
            Self.logger.log(.notice, "Catcher stood down")
            return
        }
        guard current.showing == nil, let surface else { return }
        guard surface.show(items: current.claim.items) else {
            return finish(refusing: WireError(.dragNotCurrent, debugDetail: "There is no screen to put the catcher on"))
        }
        take?.showing = Showing()
        peer.answerTake(id, .report(.armed))
        Self.logger.log(.notice, "Catcher armed again")
    }

    /// A Mac destination takes take `id`'s drag: marks the current showing to
    /// deliver it at the drop and reports `DELIVERING`, which only a take whose
    /// drag is on the surface — entered, not ended — can be. Anything else is
    /// answered `DELIVER_REFUSED`, leaving the take as it was.
    func deliver(take id: DragTakeID) {
        guard let current = take, current.id == id, !current.ended else { return }
        guard current.showing?.entered == true else {
            Self.logger.log(.notice, "Refused to deliver: the drag is not on the catcher")
            return peer.answerTake(id, .report(.deliverRefused))
        }
        take?.showing?.delivers = true
        peer.answerTake(id, .report(.delivering))
        Self.logger.log(.notice, "Catcher will deliver the drag at its drop")
    }

    /// Take `id` is over without this side ending it: the host called it off,
    /// its offer ended, or the connection closed. Only a take this side ended
    /// keeps the surface up, for the drop it must refuse.
    func cancelled(take id: DragTakeID) {
        guard let current = take, current.id == id, !current.ended else { return }
        finish()
    }

    /// The press `press` ended; a take whose drag is not on the surface has
    /// nothing left to catch, and no release to drop on it. While the surface
    /// is stood down the drag was the user's to drop inside the guest.
    func pressEnded(_ press: UInt64) {
        guard let take, take.claim.press == press, !take.caught else { return }
        guard let showing = take.showing else { return finish(.returned) }
        guard !showing.entered else { return }
        finish(refusing: WireError(.dragPressOver, debugDetail: "The press ended before the drag reached the catcher"))
    }

    /// A click reached the surface, so no drag is in flight to catch: the
    /// guest's drag manager holds the mouse while one is, and the press
    /// monitor never hears a click on this app's own window.
    func surfaceClicked() {
        guard take != nil else { return }
        finish(refusing: WireError(.dragPressOver, debugDetail: "A click reached the catcher, so no drag is in flight"))
    }

    /// The session peer stops; nothing is left to answer.
    func stop() {
        guard take != nil else { return }
        take = nil
        surface?.hide()
    }

    /// Takes the surface down and forgets the take, ending it with `answer`
    /// unless this side already ended it.
    private func finish(_ answer: DragTakeAnswer? = nil) {
        guard let ended = take else { return }
        take = nil
        surface?.hide()
        guard let answer, !ended.ended else { return }
        if case .refused(let error) = answer {
            Self.logger.log(.notice, "Catcher gave up: \(error.debugDetail, privacy: .public)")
        }
        peer.answerTake(ended.id, answer)
    }

    private func finish(refusing error: WireError) {
        finish(.refused(error))
    }

    // MARK: - Drag destination

    /// The drag entered the surface.
    func draggingEntered(_ drag: Drag) -> NSDragOperation {
        accept(drag)
    }

    /// The drag moved, or the periodic update fired, inside the surface.
    func draggingUpdated(_ drag: Drag) -> NSDragOperation {
        accept(drag)
    }

    /// Answers copy for the taken drag and nothing for anything else, which
    /// refuses the take: never move or generic, which let a source delete what
    /// it dragged. A callback with the surface stood down is answered with
    /// nothing and reports nothing.
    private func accept(_ drag: Drag) -> NSDragOperation {
        guard let current = take, let showing = current.showing, !current.ended else { return [] }
        guard drag.sourceMask.contains(.copy) else {
            decline(
                current, showing, WireError(.dragNotCurrent, debugDetail: "The drag's source does not allow a copy"))
            return []
        }
        guard drag.items == current.claim.items else {
            decline(
                current, showing,
                WireError(.dragNotCurrent, debugDetail: "The drag holds other items than the taken one"))
            return []
        }
        if !showing.entered {
            take?.showing?.entered = true
            if !showing.targeted {
                take?.showing?.targeted = true
                peer.answerTake(current.id, .report(.targeted))
                Self.logger.log(.notice, "Catcher is the drag's target")
            }
        }
        return .copy
    }

    /// Refuses `current`, keeping the surface up when the host may already
    /// have released the button onto it.
    private func decline(_ current: Take, _ showing: Showing, _ error: WireError) {
        guard showing.targeted else { return finish(refusing: error) }
        take?.ended = true
        Self.logger.log(
            .notice, "Catcher refused the drag after it was targeted: \(error.debugDetail, privacy: .public)")
        peer.answerTake(current.id, .refused(error))
    }

    /// The drag left the surface before ending.
    func draggingExited() {
        take?.showing?.entered = false
    }

    /// The drag ended on the surface. A showing the host asked to deliver hands
    /// the drop's promises, read through `receivers`, to ``onDeliver``, which
    /// ends the take; any other ends it `CAUGHT` and reads nothing of them.
    func performDragOperation(receivers: () -> [any FilePromiseReceiving]) -> Bool {
        guard let current = take, let showing = current.showing, showing.entered, !current.ended else {
            return false
        }
        take?.caught = true
        take?.ended = true
        if showing.delivers, let onDeliver {
            onDeliver(current.id, current.claim, receivers())
        } else {
            peer.answerTake(current.id, .caught(reoffer: nil))
        }
        Self.logger.log(.notice, "Catcher caught the drag (delivering: \(showing.delivers, privacy: .public))")
        return true
    }

    /// The drop on the surface is over.
    func concludeDragOperation() {
        finish()
    }

    /// The drag ended, wherever it ended; with the surface stood down it was
    /// the user's to drop inside the guest.
    func draggingEnded() {
        guard let current = take else { return }
        guard current.showing != nil else { return finish(.returned) }
        guard !current.caught else { return finish() }
        finish(refusing: WireError(.dragPressOver, debugDetail: "The drag ended without reaching the catcher"))
    }
}
