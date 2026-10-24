import Foundation
import KernovaKit
import KernovaLogging

/// Offers the host each drag in this guest that carries plain file URLs, for as
/// long as the press that started it is held.
///
/// Scoped to presses: a global monitor starts one for each primary-button
/// press, and a timer runs only while the button stays down, reading the drag
/// pasteboard whenever its change count has moved past the press's baseline.
/// The baseline is the count at the previous press's end (or at ``start()``),
/// never a read taken when the press is heard of — a monitor's event arrives
/// after the fact, so a count read then can already include this press's drag.
///
/// One offer per press at a time. Changed items replace it; the press ending
/// withdraws it unless the host has taken it, and a taken offer is never
/// withdrawn here — the host's `DragComplete` retires it.
@MainActor
final class GuestDragWatcher {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestDragWatcher")

    /// How often a held press reads the drag pasteboard: short enough that an
    /// offer is in place before the pointer reaches the display edge.
    static let tickInterval: TimeInterval = 0.05

    /// Why ``claim(generation:)`` refused a take.
    enum ClaimRefusal: Error, Equatable {
        /// The take names no offer this press holds, or one already taken.
        case notCurrent
        /// The press that carried the offer is no longer held.
        case pressOver

        /// Log detail for the host.
        var message: String {
            switch self {
            case .notCurrent: "The take names no drag the guest is offering"
            case .pressOver: "The press that carried the drag is over"
            }
        }
    }

    /// A drag a take has claimed: what the catcher must see arrive.
    struct Claim: Equatable {
        let generation: UInt64
        /// The press the drag belongs to.
        let press: UInt64
        /// The file URLs the offer was made from, in drag order.
        let fileURLs: [URL]
    }

    private let input: any GuestDragInput
    private let peer: any GuestDragOutPeer

    /// Told each time a press ends, with its id.
    var onPressEnded: ((UInt64) -> Void)?

    // MARK: - State

    /// What the current press has offered.
    private enum Phase: Equatable {
        /// Nothing is offered.
        case watching
        /// `offer` is live and the host has not taken it.
        case offered(Offer)
        /// A take claimed the offer, or the host retired it:
        /// the press offers nothing more, and nothing here withdraws it.
        case settled
    }

    private struct Offer: Equatable {
        let generation: UInt64
        let fileURLs: [URL]
        /// The change count the offer's items were last read at.
        var changeCount: Int
    }

    /// The primary-button press being watched, from its monitor event until a
    /// tick sees the button up.
    private struct Press {
        let id: UInt64
        /// The count the last tick read, standing in for the press's end when a
        /// newer press arrives before any tick saw the button go up.
        var lastObservedCount: Int
        var phase: Phase = .watching
        /// The file URLs whose resolve is in flight, so a tick starts no second
        /// walk of the same items and a superseded walk's result is dropped.
        var resolving: [URL]?
        /// The file URLs whose resolve came back unofferable, so an unchanged
        /// drag is not walked again every tick.
        var unofferable: [URL]?
    }

    private var isRunning = false
    private var press: Press?
    private var nextPressID: UInt64 = 1

    /// The drag pasteboard's count at the previous press's end.
    private var baseline = 0

    private var endPressMonitor: GuestDragCancel?
    private var endTicks: GuestDragCancel?
    private var endActivity: GuestDragCancel?

    init(input: any GuestDragInput, peer: any GuestDragOutPeer) {
        self.input = input
        self.peer = peer
    }

    // MARK: - Lifecycle

    /// Begins watching presses; idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        baseline = input.dragPasteboard.changeCount
        endActivity = input.holdActivity(reason: "Kernova drag-out watcher")
        endPressMonitor = input.observePrimaryPresses { [weak self] in self?.pressBegan() }
        Self.logger.log(.notice, "Watching for drags out of the guest")
    }

    /// Stops watching, withdrawing an offer the host has not taken; idempotent.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        endPressMonitor?()
        endPressMonitor = nil
        if let press { end(press, at: press.lastObservedCount) }
        endActivity?()
        endActivity = nil
        Self.logger.log(.notice, "Stopped watching for drags out of the guest")
    }

    // MARK: - Presses

    private func pressBegan() {
        guard isRunning else { return }
        // A release no tick saw: the previous press ended somewhere in the last
        // interval, and its last read is the latest count known to predate this
        // press's own drag.
        if let previous = press { end(previous, at: previous.lastObservedCount) }
        let id = nextPressID
        nextPressID += 1
        press = Press(id: id, lastObservedCount: baseline)
        endTicks = input.repeatEvery(Self.tickInterval) { [weak self] in self?.tick() }
    }

    private func end(_ ended: Press, at changeCount: Int) {
        press = nil
        baseline = changeCount
        endTicks?()
        endTicks = nil
        if case .offered(let offer) = ended.phase {
            _ = peer.withdraw(generation: offer.generation)
        }
        onPressEnded?(ended.id)
    }

    private func tick() {
        guard let current = press else { return }
        let count = input.dragPasteboard.changeCount
        guard input.isPrimaryButtonHeld else {
            end(current, at: count)
            return
        }
        press?.lastObservedCount = count
        guard count != baseline else { return }
        switch current.phase {
        case .settled:
            return
        case .offered(let offer) where offer.changeCount == count:
            return
        case .offered, .watching:
            read(at: count)
        }
    }

    /// Reads the drag pasteboard of a press whose count has moved, replacing or
    /// withdrawing an offer its items no longer match and resolving new ones.
    private func read(at count: Int) {
        guard let current = press else { return }
        let urls = GuestDraggedFiles.fileURLs(on: input.dragPasteboard)
        if case .offered(var offer) = current.phase {
            if urls == offer.fileURLs {
                offer.changeCount = count
                press?.phase = .offered(offer)
                return
            }
            _ = peer.withdraw(generation: offer.generation)
            press?.phase = .watching
        }
        guard let urls, urls != current.resolving, urls != current.unofferable else { return }
        press?.resolving = urls
        let pressID = current.id
        input.resolveFiles(urls) { [weak self] intake in
            self?.resolved(intake, from: urls, readAt: count, press: pressID)
        }
    }

    /// Offers what a resolve produced, if the press it was read for is still
    /// the current, held one.
    private func resolved(
        _ intake: ClipboardPasteboardReader.FileIntake, from urls: [URL], readAt count: Int,
        press pressID: UInt64
    ) {
        guard isRunning, let current = press, current.id == pressID, current.resolving == urls
        else { return }
        press?.resolving = nil
        // Checked here, immediately before the offer goes out, rather than left
        // to the next tick: a host that took an offer whose press had already
        // ended would arm the catcher for a drag that is over.
        guard input.isPrimaryButtonHeld, case .watching = current.phase else { return }
        guard let content = GuestDraggedFiles.offerableContent(intake, resolvedFrom: urls) else {
            press?.unofferable = urls
            return
        }
        switch peer.offer(content, skippedBeforeOffer: 0) {
        case .sent(let generation):
            press?.phase = .offered(Offer(generation: generation, fileURLs: urls, changeCount: count))
            Self.logger.log(
                .notice,
                "Offered a drag of \(urls.count, privacy: .public) item(s) to the host (gen=\(generation, privacy: .public))"
            )
        case .duplicate, .nothingToOffer, .sendFailed:
            press?.unofferable = urls
        }
    }

    // MARK: - Takes

    /// Hands the offer under `generation` to a take, which it can be only while
    /// it is the current press's untaken offer and that press is still held.
    func claim(generation: UInt64) -> Result<Claim, ClaimRefusal> {
        guard let current = press, case .offered(let offer) = current.phase,
            offer.generation == generation
        else { return .failure(.notCurrent) }
        guard input.isPrimaryButtonHeld else { return .failure(.pressOver) }
        press?.phase = .settled
        return .success(Claim(generation: generation, press: current.id, fileURLs: offer.fileURLs))
    }

    /// Lets go of the offer under `generation`, which the host has retired; the
    /// press offers nothing more.
    func forget(generation: UInt64) {
        guard case .offered(let offer) = press?.phase, offer.generation == generation else { return }
        press?.phase = .settled
    }
}
