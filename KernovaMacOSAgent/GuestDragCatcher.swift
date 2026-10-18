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
/// The surface covers the screen and takes mouse events, so while it is up the
/// guest cannot be clicked: every path that shows it ends at ``finish(failing:)``
/// — the drag concluding or ending, a failure, the host completing the drag,
/// the connection ending, or the press ending before the drag entered.
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
        /// The drag ended on the surface; its items stay pullable.
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

    /// The press `press` ended; a take whose drag never reached the surface
    /// has nothing left to catch.
    func pressEnded(_ press: UInt64) {
        guard let take, take.claim.press == press, !take.entered, !take.caught else { return }
        finish(failing: (.dragTakeFailed, "The press ended before the drag reached the catcher"))
    }

    /// The host is done with `generation`.
    func complete(generation: UInt64) {
        guard take?.claim.generation == generation else { return }
        finish(failing: nil)
    }

    /// The connection ended; nothing is left to report to.
    func stop() {
        guard take != nil else { return }
        take = nil
        surface?.hide()
    }

    /// Takes the surface down and forgets the take, telling the host first
    /// when it failed.
    private func finish(failing failure: (code: ClipboardErrorCode, message: String)?) {
        guard let ended = take else { return }
        take = nil
        surface?.hide()
        guard let failure else { return }
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
        guard let current = take, !current.caught else { return [] }
        guard drag.sourceMask.contains(.copy) else {
            finish(failing: (.dragTakeRefused, "The drag's source does not allow a copy"))
            return []
        }
        guard drag.fileURLs == current.claim.fileURLs else {
            finish(failing: (.dragTakeRefused, "The drag holds other items than the taken one"))
            return []
        }
        if !current.entered {
            take?.entered = true
            send(.targeted, for: current.claim.generation)
        }
        return .copy
    }

    /// The drag left the surface before ending.
    func draggingExited() {
        take?.entered = false
    }

    /// The drag ended on the surface.
    func performDragOperation() -> Bool {
        guard let current = take, current.entered, !current.caught else { return false }
        take?.caught = true
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
