import Foundation

/// How one take's delivery came out: the offer that carries the drag on, named
/// and sized, or none.
///
/// Settled from the transport's queue, never the main actor's: a Mac
/// destination asks a promised item's name on the main thread
/// (`filePromiseProvider(_:fileNameForType:)` is `NS_SWIFT_UI_ACTOR` in
/// `NSFilePromiseProvider.h`) and the answer must return synchronously, so that
/// ask holds the main thread while the guest calls the promises in, and
/// everything it waits for arrives here without it.
package final class GuestDragDelivery: @unchecked Sendable {
    /// What the drag's delivery left the host to pull from.
    package enum Outcome: Equatable, Sendable {
        /// The guest offered the drag again as `token`, carrying `items` in the
        /// taken offer's order.
        case delivered(token: Data, items: [DraggedOutItem])
        /// No delivery: the taken offer still carries what it can.
        case undelivered
    }

    private let condition = NSCondition()
    /// The guest answered the ask for a delivering drop, so the button may be
    /// released onto its catcher.
    private var answered = false
    /// The answer has been acted on, so a later waiter does not release again.
    private var answerTaken = false
    private var outcome: Outcome?
    private var onSettled: (@Sendable () -> Void)?

    package init() {}

    /// Calls `body` once the delivery settles, or now when it has; once.
    package func whenSettled(_ body: @escaping @Sendable () -> Void) {
        condition.lock()
        let settled = outcome != nil
        if !settled { onSettled = body }
        condition.unlock()
        if settled { body() }
    }

    /// How the delivery settled, or nil while it has not.
    package var settled: Outcome? {
        condition.lock()
        defer { condition.unlock() }
        return outcome
    }

    /// The guest answered the ask for a delivering drop, `DELIVERING` or
    /// `DELIVER_REFUSED`.
    package func peerAnswered() {
        condition.lock()
        answered = true
        condition.broadcast()
        condition.unlock()
    }

    /// Settles the delivery, once; a later settle changes nothing.
    package func settle(_ settled: Outcome) {
        condition.lock()
        guard outcome == nil else { return condition.unlock() }
        outcome = settled
        let body = onSettled
        onSettled = nil
        condition.broadcast()
        condition.unlock()
        body?()
    }

    /// Blocks the calling thread until the delivery settles, and returns how.
    ///
    /// `release` is called on this thread, once across every waiter, when the
    /// guest answers the ask before the delivery settles: a waiter on the main
    /// thread is the one that can inject the release the delivery waits for.
    /// No wall clock bounds the wait: the take's end settles it.
    package func wait(releasing release: (() -> Void)?) -> Outcome {
        condition.lock()
        while outcome == nil {
            if answered, !answerTaken, let release {
                answerTaken = true
                condition.unlock()
                release()
                condition.lock()
                continue
            }
            condition.wait()
        }
        let settled = outcome ?? .undelivered
        condition.unlock()
        return settled
    }
}
