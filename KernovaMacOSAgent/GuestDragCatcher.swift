import AppKit
import Foundation
import KernovaKit
import KernovaLogging

/// Ends a drag the host has taken over by being its destination: a surface
/// over the whole screen under the guest pointer, answering copy so the source
/// keeps its items, and reporting each step of the hand-off to the host.
///
/// The steps go `armed` (the surface is up), `targeted` (the guest's drag
/// manager entered it with the taken drag, answered copy), then `caught` (the
/// drag ended on it). The host releases the guest's button only after
/// `targeted`, so anything else arriving before then — the wrong items, a
/// source that forbids a copy — is answered with no operation and `failed`.
///
/// Once `targeted` is out the host may already have released the button, and
/// that release is a real drop under the guest pointer, so a refusal after
/// `targeted` leaves the surface up until the guest's drag ends, to refuse
/// whatever drops on it. The host completing a take this side did not refuse
/// takes the surface down at once: the host completes a released take only
/// after this side's `caught` or `failed`, or on supersession, which needs a
/// newer guest press and so follows the old drop — so a completion before
/// then means the host gave the press back without releasing, and the user's
/// drag goes on in the guest.
///
/// The surface covers the screen and takes mouse events, so while it is up the
/// guest cannot be clicked: every path that shows it ends at ``finish(failing:)``
/// — the drag concluding or ending, a failure before `targeted`, the host
/// completing the drag, the connection ending, or the press ending while the
/// drag is off the surface.
@MainActor
final class GuestDragCatcher {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestDragCatcher")

    /// What one guest drag callback shows the catcher.
    struct Drag: Equatable {
        /// The operations the drag's source allows.
        let sourceMask: NSDragOperation
        /// The drag's file URLs under ``GuestDraggedFiles``' rule, or `nil`
        /// when it carries anything else.
        let fileURLs: [URL]?
    }

    /// The drag a take armed the catcher for.
    private struct Take {
        let claim: GuestDragWatcher.Claim
        /// The guest's drag manager is inside the surface with the taken drag.
        var entered = false
        /// `targeted` went out, so the host may have released the button.
        var targeted = false
        /// The take was refused after `targeted`: the surface stays up and
        /// refuses the drop.
        var refused = false
        /// The drag ended on the surface; its items stay pullable.
        var caught = false
    }

    private let peer: any GuestDragOutPeer
    private let grants: GuestDropGrants
    private let makeSurface: @MainActor (GuestDragCatcher) -> any GuestDragCatcherSurface
    private var surface: (any GuestDragCatcherSurface)?
    private var take: Take?

    init(
        peer: any GuestDragOutPeer,
        grants: GuestDropGrants,
        makeSurface: @escaping @MainActor (GuestDragCatcher) -> any GuestDragCatcherSurface
    ) {
        self.peer = peer
        self.grants = grants
        self.makeSurface = makeSurface
    }

    // MARK: - Takes

    /// Puts the surface up for a drag the watcher has handed over, and tells
    /// the host it is armed.
    func arm(_ claim: GuestDragWatcher.Claim) {
        if let previous = take {
            finish(failing: previous.caught ? nil : (.dragTakeFailed, "A newer take replaced this one"))
        }
        let surface = surface ?? makeSurface(self)
        self.surface = surface
        take = Take(claim: claim)
        guard surface.show() else {
            finish(failing: (.dragTakeFailed, "There is no screen to put the catcher on"))
            return
        }
        send(.armed, for: claim.generation)
        Self.logger.log(.notice, "Catcher armed (gen=\(claim.generation, privacy: .public))")
    }

    /// Tells the host its take of `generation` cannot proceed, leaving any
    /// live take alone.
    func refuse(generation: UInt64, code: ClipboardErrorCode, message: String) {
        Self.logger.log(
            .notice,
            "Refused the host's take (gen=\(generation, privacy: .public)): \(message, privacy: .public)"
        )
        send(.failed(code, message: message), for: generation)
    }

    /// The press `press` ended; a take whose drag is not on the surface has
    /// nothing left to catch, and no release to drop on it.
    func pressEnded(_ press: UInt64) {
        guard let take, take.claim.press == press, !take.entered, !take.caught else { return }
        finish(failing: (.dragTakeFailed, "The press ended before the drag reached the catcher"))
    }

    /// The host is done with `generation`; only a take this side refused
    /// after `targeted` keeps the surface up, for the drop it must refuse.
    func complete(generation: UInt64) {
        guard let current = take, current.claim.generation == generation, !current.refused else {
            return
        }
        finish(failing: nil)
    }

    /// The connection ended; nothing is left to report to.
    func stop() {
        guard take != nil else { return }
        take = nil
        surface?.hide()
    }

    /// Takes the surface down and forgets the take, telling the host first
    /// when it failed — unless a refusal already told it.
    private func finish(failing failure: (code: ClipboardErrorCode, message: String)?) {
        guard let ended = take else { return }
        take = nil
        surface?.hide()
        guard let failure, !ended.refused else { return }
        Self.logger.log(
            .notice,
            "Catcher gave up (gen=\(ended.claim.generation, privacy: .public)): \(failure.message, privacy: .public)"
        )
        send(.failed(failure.code, message: failure.message), for: ended.claim.generation)
    }

    private func send(_ step: ClipboardDragHandOffStep, for generation: UInt64) {
        peer.sendDragHandOff(generation: generation, step: step)
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
    /// fails the take: never move or generic, which let a source delete what
    /// it dragged.
    private func accept(_ drag: Drag) -> NSDragOperation {
        guard let current = take, !current.caught, !current.refused else { return [] }
        guard drag.sourceMask.contains(.copy) else {
            decline(current, (.dragTakeRefused, "The drag's source does not allow a copy"))
            return []
        }
        guard drag.fileURLs == current.claim.fileURLs else {
            decline(current, (.dragTakeRefused, "The drag holds other items than the taken one"))
            return []
        }
        if !current.entered {
            take?.entered = true
            take?.targeted = true
            send(.targeted, for: current.claim.generation)
        }
        return .copy
    }

    /// Fails `current`, keeping the surface up when the host may already have
    /// released the button onto it.
    private func decline(_ current: Take, _ failure: (code: ClipboardErrorCode, message: String)) {
        guard current.targeted else {
            finish(failing: failure)
            return
        }
        take?.refused = true
        Self.logger.log(
            .notice,
            "Catcher refused the drag after it was targeted (gen=\(current.claim.generation, privacy: .public)): \(failure.message, privacy: .public)"
        )
        send(.failed(failure.code, message: failure.message), for: current.claim.generation)
    }

    /// The drag left the surface before ending.
    func draggingExited() {
        take?.entered = false
    }

    /// The drag ended on the surface, delivering `dropped`: the URL objects
    /// the drop read, whose access is held before `caught` lets the host pull.
    func performDragOperation(dropped: [URL]) -> Bool {
        guard let current = take, current.entered, !current.caught, !current.refused else { return false }
        take?.caught = true
        grants.hold(dropped, for: current.claim.generation)
        send(.caught, for: current.claim.generation)
        return true
    }

    /// The drop on the surface is over.
    func concludeDragOperation() {
        finish(failing: nil)
    }

    /// The drag ended, wherever it ended.
    func draggingEnded() {
        guard let current = take else { return }
        finish(failing: current.caught ? nil : (.dragTakeFailed, "The drag ended without reaching the catcher"))
    }
}
