import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaLogging
import KernovaWire

/// Offers the host each drag in this guest that ``GuestDraggedItems`` lets go
/// out, for as long as the press that started it is held: an offer that lists
/// no items and says only that such a drag is in progress. The source may
/// still be writing the drag pasteboard while this reads it, so the drag's
/// items come from the catcher once a take arms it, as the drag's destination
/// sees them.
///
/// Scoped to presses: a global monitor starts one for each primary-button
/// press, and a timer runs only while the button stays down, reading the drag
/// pasteboard whenever its change count has moved past the press's baseline.
/// The baseline is the count at the previous press's end (or at ``start()``),
/// never a read taken when the press is heard of — a monitor's event arrives
/// after the fact, so a count read then can already include this press's drag.
///
/// One offer per press at a time. Items no drag goes out with withdraw it; the
/// press ending withdraws it unless the host has taken it, and a taken offer
/// is never withdrawn here — the host's release ends it.
@MainActor
final class GuestDragWatcher {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestDragWatcher")

    /// How often a held press reads the drag pasteboard: short enough that an
    /// offer is in place before the pointer reaches the display edge.
    static let tickInterval: TimeInterval = 0.05

    /// Why ``claim(token:)`` refused a take.
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

        /// The take's refusal on the wire.
        var error: WireError {
            switch self {
            case .notCurrent: WireError(.dragNotCurrent, debugDetail: message)
            case .pressOver: WireError(.dragPressOver, debugDetail: message)
            }
        }
    }

    /// A drag a take has claimed: its offer, and the press it belongs to.
    struct Claim: Equatable {
        let token: Data
        /// The press the drag belongs to.
        let press: UInt64
        /// The items the drag pasteboard held as the take claimed it, which the
        /// source may still have been writing: what the catcher's box shows
        /// until the catcher reads the drag itself.
        let preview: [GuestDragItem]
    }

    private let input: any GuestDragInput
    private let peer: any GuestDragOutPeer

    /// Told each time a press ends, with its id.
    var onPressEnded: ((UInt64) -> Void)?

    // MARK: - State

    /// What the current press has offered.
    private enum Phase {
        /// Nothing is offered.
        case watching
        /// `offer` is out and the host has not taken it.
        case offered(Offer)
        /// A take claimed the offer, or the host ended it: the press offers
        /// nothing more, and nothing here withdraws it.
        case settled
    }

    private struct Offer {
        let token: Data
        /// The change count the drag was last read at.
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
        if case .offered(let offer) = ended.phase { withdraw(offer) }
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

    /// Reads the drag pasteboard of a press whose count has moved: a drag that
    /// can go out is offered, once, and one that cannot withdraws the offer.
    private func read(at count: Int) {
        guard let current = press else { return }
        let offerable = GuestDraggedItems.items(on: input.dragPasteboard) != nil
        switch current.phase {
        case .offered(var offer):
            guard offerable else {
                withdraw(offer)
                press?.phase = .watching
                return
            }
            offer.changeCount = count
            press?.phase = .offered(offer)
        case .watching:
            guard offerable else { return }
            offer(Offer(token: Self.token(), changeCount: count))
        case .settled:
            break
        }
    }

    /// Offers the drag `offer` names and makes it the press's.
    private func offer(_ offer: Offer) {
        let token = offer.token
        press?.phase = .offered(offer)
        peer.offerDrag(ItemOffer(token: token, items: [])) { [weak self] refusal in
            guard let self, let refusal else { return }
            Self.logger.log(
                .error, "The host refused the drag offer: \(String(describing: refusal.code), privacy: .public)")
            guard case .offered(let current) = self.press?.phase, current.token == token else { return }
            self.press?.phase = .settled
        }
        Self.logger.log(.notice, "Offered a drag in progress to the host")
    }

    private func withdraw(_ offer: Offer) {
        peer.withdrawDrag(offer.token)
    }

    static func token() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: - Takes

    /// Hands the offer of `token` to a take, which it can be only while it is
    /// the current press's untaken offer and that press is still held.
    func claim(token: Data) -> Result<Claim, ClaimRefusal> {
        guard let current = press, case .offered(let offer) = current.phase, offer.token == token
        else { return .failure(.notCurrent) }
        guard input.isPrimaryButtonHeld else { return .failure(.pressOver) }
        press?.phase = .settled
        let preview = GuestDraggedItems.items(on: input.dragPasteboard) ?? []
        return .success(Claim(token: token, press: current.id, preview: preview))
    }

    /// Lets go of the offer of `token`, which has ended; the press offers
    /// nothing more.
    func forget(token: Data) {
        guard case .offered(let offer) = press?.phase, offer.token == token else { return }
        press?.phase = .settled
    }
}
