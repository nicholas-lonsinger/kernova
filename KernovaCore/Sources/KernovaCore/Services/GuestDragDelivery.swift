import Foundation

/// How one take's delivery came out: what its drop named, then what it
/// delivered.
///
/// Settled from the transport's queue, never the main actor's: a Mac
/// destination asks a promised item's name on the main thread
/// (`filePromiseProvider(_:fileNameForType:)` is `NS_SWIFT_UI_ACTOR` in
/// `NSFilePromiseProvider.h`) and the answer must return synchronously, so that
/// ask holds the main thread while the guest calls the promises in, and
/// everything it waits for arrives here without it. The ask waits only for
/// the names, never for the folder sizes the delivery settles with after.
package final class GuestDragDelivery: @unchecked Sendable {
    /// What the drag's delivery left the host to pull.
    package enum Outcome: Equatable, Sendable {
        /// The drop delivered the drag: its items in the taken offer's order,
        /// each promise under the name it took and each folder sized.
        case delivered([DraggedOutItem])
        /// No delivery: the taken offer carries the drag as offered.
        case undelivered
    }

    /// What a name ask learns.
    package enum Naming: Equatable, Sendable {
        /// The drag's items, each promise under the name it took.
        case named([DraggedOutItem])
        /// Nothing names the promises.
        case unnamed
    }

    private let condition = NSCondition()
    /// The guest answered the ask for a delivering drop, so the button may be
    /// released onto its catcher.
    private var answered = false
    /// The answer has been acted on, so a later waiter does not release again.
    private var answerTaken = false
    private var names: [DraggedOutItem]?
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

    /// What names the drag's promises, or nil while nothing has yet.
    package var naming: Naming? {
        condition.lock()
        defer { condition.unlock() }
        return currentNaming
    }

    private var currentNaming: Naming? {
        if let names { return .named(names) }
        switch outcome {
        case .delivered(let items)?: return .named(items)
        case .undelivered?: return .unnamed
        case nil: return nil
        }
    }

    /// The guest answered the ask for a delivering drop, `DELIVERING` or
    /// `DELIVER_REFUSED`.
    package func peerAnswered() {
        condition.lock()
        answered = true
        condition.broadcast()
        condition.unlock()
    }

    /// The drop named the drag's promises: `items`, before their folders are
    /// sized. Once; a later naming, or one after the delivery settled, changes
    /// nothing.
    package func named(_ items: [DraggedOutItem]) {
        condition.lock()
        if names == nil, outcome == nil { names = items }
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

    /// Blocks the calling thread until something names the drag's promises,
    /// and returns what.
    ///
    /// `release` is called on this thread, once across every waiter, when the
    /// guest answers the ask before anything names them: a waiter on the main
    /// thread is the one that can inject the release the naming waits for. No
    /// wall clock bounds the wait: the take's end settles it.
    package func waitForNames(releasing release: (() -> Void)?) -> Naming {
        condition.lock()
        while currentNaming == nil {
            if answered, !answerTaken, let release {
                answerTaken = true
                condition.unlock()
                release()
                condition.lock()
                continue
            }
            condition.wait()
        }
        let naming = currentNaming ?? .unnamed
        condition.unlock()
        return naming
    }
}
