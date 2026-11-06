import Foundation
import KernovaKit

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
///
/// The names are owed within ``namingDeadline`` of the first ask; past it the
/// delivery settles as ``Outcome/expired(after:)``.
package final class GuestDragDelivery: @unchecked Sendable {
    /// What the drag's delivery left the host to pull.
    package enum Outcome: Equatable, Sendable {
        /// The drop delivered the drag: its items in the taken offer's order,
        /// each promise under the name it took and each folder sized.
        case delivered([DraggedOutItem])
        /// No delivery: the taken offer carries the drag as offered.
        case undelivered
        /// Nothing named the promises within ``GuestDragDelivery/namingDeadline``
        /// of the first ask, `after` that many seconds: nothing is delivered,
        /// and the take is owed its end.
        case expired(after: TimeInterval)
    }

    /// How long the drag's promises may go unnamed once a destination first
    /// asks a name: Finder abandons a pasteboard promise it has waited 60 s
    /// for (docs/research/2026-07-27-pasteboard-promise-deadlines.md).
    package static let namingDeadline: TimeInterval = 60

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
    private let clock: any EngineClock
    /// When a destination first asked a name, from which ``namingDeadline``
    /// runs for every waiter.
    private var firstAsk: EngineInstant?
    /// What settles the delivery as expired at ``namingDeadline``, until
    /// something names the promises first.
    private var deadline: Task<Void, Never>?

    /// A delivery whose naming deadline runs on `clock`.
    package init(clock: any EngineClock = makePlatformEngineClock()) {
        self.clock = clock
    }

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
        case .undelivered?, .expired?: return .unnamed
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
        if names == nil, outcome == nil {
            names = items
            stopDeadline()
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Settles the delivery, once; a later settle changes nothing.
    package func settle(_ settled: Outcome) {
        condition.lock()
        guard outcome == nil else { return condition.unlock() }
        let body = settleLocked(settled)
        condition.unlock()
        body?()
    }

    /// Settles the delivery as expired when nothing has named its promises.
    private func expire() {
        condition.lock()
        guard names == nil, outcome == nil, let firstAsk else { return condition.unlock() }
        let body = settleLocked(.expired(after: firstAsk.seconds(to: clock.now)))
        condition.unlock()
        body?()
    }

    /// Records `settled`, waking every waiter, and returns what to call once
    /// the lock is released.
    private func settleLocked(_ settled: Outcome) -> (@Sendable () -> Void)? {
        outcome = settled
        stopDeadline()
        let body = onSettled
        onSettled = nil
        condition.broadcast()
        return body
    }

    private func stopDeadline() {
        deadline?.cancel()
        deadline = nil
    }

    /// Blocks the calling thread until something names the drag's promises,
    /// and returns what.
    ///
    /// `release` is called on this thread, once across every waiter, when the
    /// guest answers the ask before anything names them: a waiter on the main
    /// thread is the one that can inject the release the naming waits for.
    ///
    /// The wait ends at ``namingDeadline`` after the first ask, shared by every
    /// waiter, with ``Naming/unnamed`` and the delivery settled as
    /// ``Outcome/expired(after:)``, unless the names or the take's end settle
    /// it first.
    package func waitForNames(releasing release: (() -> Void)?) -> Naming {
        condition.lock()
        if currentNaming == nil, firstAsk == nil {
            firstAsk = clock.now
            deadline = clock.schedule(after: Self.namingDeadline) { [weak self] in self?.expire() }
        }
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
