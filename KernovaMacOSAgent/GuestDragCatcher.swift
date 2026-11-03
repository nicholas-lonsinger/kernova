import AppKit
import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaLogging
import KernovaWire

/// Ends a drag the host has taken over by being its destination: a surface
/// over the whole screen under the guest pointer, answering copy so the source
/// keeps its items, and answering the host's take once it is the drag's
/// target.
///
/// The host releases the guest's button onto the surface only after the take
/// is answered `TAKEN`, so anything arriving before then — the wrong items, a
/// source that forbids a copy, the press ending — refuses the take and takes
/// the surface down, and the host hands the press back.
///
/// Once `TAKEN` is out the host may already have released the button, and
/// that release is a real drop under the guest pointer, so from then on the
/// surface stays up until the guest's drag ends, whatever becomes of the
/// offer: the drag ends on it, or a later refusal leaves it up to refuse the
/// drop. Before `TAKEN`, the offer ending takes it down at once: the host
/// released nothing onto it.
///
/// The surface covers the screen and takes mouse events, so while it is up the
/// guest cannot be clicked: every path that shows it ends at ``finish()`` —
/// the drag concluding or ending, a refusal before `TAKEN`, the offer ending
/// before it, the press ending while the drag is off the surface, or a click
/// reaching the surface, which no drag in flight lets happen.
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

    /// The drag a take armed the catcher for.
    private struct Take {
        let claim: GuestDragWatcher.Claim
        let id: DragTakeID
        /// The guest's drag manager is inside the surface with the taken drag.
        var entered = false
        /// `TAKEN` went out, so the host may have released the button.
        var answered = false
        /// The take was refused after `TAKEN`: the surface stays up and
        /// refuses the drop.
        var refused = false
        /// The drag ended on the surface.
        var caught = false
    }

    private let peer: any GuestDragOutPeer
    private let makeSurface: @MainActor (GuestDragCatcher) -> any GuestDragCatcherSurface
    private var surface: (any GuestDragCatcherSurface)?
    private var take: Take?

    init(
        peer: any GuestDragOutPeer,
        makeSurface: @escaping @MainActor (GuestDragCatcher) -> any GuestDragCatcherSurface
    ) {
        self.peer = peer
        self.makeSurface = makeSurface
    }

    // MARK: - Takes

    /// Puts the surface up for a drag the watcher has handed to the take `id`.
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
        Self.logger.log(.notice, "Catcher armed for the host's take")
    }

    /// The press `press` ended; a take whose drag is not on the surface has
    /// nothing left to catch, and no release to drop on it.
    func pressEnded(_ press: UInt64) {
        guard let take, take.claim.press == press, !take.caught, !take.entered else { return }
        finish(refusing: WireError(.dragPressOver, debugDetail: "The press ended before the drag reached the catcher"))
    }

    /// The offer of `token` ended. Before `TAKEN` the host released nothing
    /// onto the surface, so it comes down at once; the take itself was
    /// refused with the offer.
    func offerEnded(token: Data) {
        guard let current = take, current.claim.token == token, !current.answered else { return }
        take = nil
        surface?.hide()
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

    /// Takes the surface down and forgets the take, refusing it with `error`
    /// unless it was answered.
    private func finish(refusing error: WireError? = nil) {
        guard let ended = take else { return }
        take = nil
        surface?.hide()
        guard let error, !ended.answered else { return }
        Self.logger.log(.notice, "Catcher gave up: \(error.debugDetail, privacy: .public)")
        peer.answerTake(ended.id, .refused(error))
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
    /// refuses the take: never move or generic, which let a source delete
    /// what it dragged.
    private func accept(_ drag: Drag) -> NSDragOperation {
        guard let current = take, !current.caught, !current.refused else { return [] }
        guard drag.sourceMask.contains(.copy) else {
            decline(current, WireError(.dragNotCurrent, debugDetail: "The drag's source does not allow a copy"))
            return []
        }
        guard drag.items == current.claim.items else {
            decline(current, WireError(.dragNotCurrent, debugDetail: "The drag holds other items than the taken one"))
            return []
        }
        take?.entered = true
        if !current.answered {
            take?.answered = true
            peer.answerTake(current.id, .taken)
            Self.logger.log(.notice, "Catcher is the drag's target; answered the host's take")
        }
        return .copy
    }

    /// Refuses `current`, keeping the surface up when the host may already
    /// have released the button onto it.
    private func decline(_ current: Take, _ error: WireError) {
        guard current.answered else { return finish(refusing: error) }
        take?.refused = true
        Self.logger.log(.notice, "Catcher refused the drag after taking it: \(error.debugDetail, privacy: .public)")
    }

    /// The drag left the surface before ending.
    func draggingExited() {
        take?.entered = false
    }

    /// The drag ended on the surface: the offer, not the drop, carries its
    /// items.
    func performDragOperation() -> Bool {
        guard let current = take, current.entered, current.answered, !current.caught, !current.refused else {
            return false
        }
        take?.caught = true
        return true
    }

    /// The drop on the surface is over.
    func concludeDragOperation() {
        finish()
    }

    /// The drag ended, wherever it ended.
    func draggingEnded() {
        guard let current = take else { return }
        finish(
            refusing: current.caught
                ? nil : WireError(.dragPressOver, debugDetail: "The drag ended without reaching the catcher"))
    }
}
