import Foundation

/// Runs blocking jobs on a concurrent queue, no more than `width` of them at a
/// time.
///
/// A job parked in a blocking read owns a libdispatch worker for as long as it
/// waits, so an unbounded fan-out of such jobs is a thread count whoever
/// submits them gets to choose. Work over the width waits here as a queued
/// closure instead — the bound is on threads, which is what a plain
/// `.concurrent` queue cannot express and a semaphore taken *inside* a job
/// cannot either, since waiting on one already holds the worker.
///
/// FIFO among the jobs that wait. A submitted job always runs: the queue keeps
/// itself alive until every one of them has, so an owner that goes away first
/// still leaves each job to release what it holds.
final class BoundedWorkQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    private let width: Int

    private let lock = NSLock()
    /// Jobs admitted and not yet finished — one worker each.
    private var running = 0
    private var waiting: [@Sendable () -> Void] = []

    /// Creates a queue running at most `width` jobs at once on `queue`.
    init(width: Int, queue: DispatchQueue) {
        self.width = max(1, width)
        self.queue = queue
    }

    /// Runs `job` now, or as soon as a slot frees.
    func submit(_ job: @escaping @Sendable () -> Void) {
        let admitted = lock.withLock { () -> Bool in
            guard running < width else {
                waiting.append(job)
                return false
            }
            running += 1
            return true
        }
        guard admitted else { return }
        // `self` is captured strongly: the worker this slot occupies is what
        // drains the jobs queued behind it.
        queue.async { [self] in
            var next: (@Sendable () -> Void)? = job
            while let run = next {
                run()
                next = lock.withLock { () -> (@Sendable () -> Void)? in
                    guard !waiting.isEmpty else {
                        running -= 1
                        return nil
                    }
                    return waiting.removeFirst()
                }
            }
        }
    }

    #if DEBUG
    /// Jobs running right now, which is also the workers this queue holds.
    var runningCountForTesting: Int { lock.withLock { running } }

    /// Jobs submitted and waiting for a slot.
    var waitingCountForTesting: Int { lock.withLock { waiting.count } }
    #endif
}
