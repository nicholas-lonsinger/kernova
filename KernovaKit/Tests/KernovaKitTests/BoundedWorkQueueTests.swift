import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The bound a queue of blocking jobs is held to, and that every job submitted
/// under it still runs.
@Suite("BoundedWorkQueue")
struct BoundedWorkQueueTests {
    /// Counts jobs as they start and finish, and reports the high-water mark of
    /// how many ran at once.
    private final class RunTally: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private var peak = 0
        private var finished = 0
        let gate = AsyncGate()

        var concurrentPeak: Int { lock.withLock { peak } }
        var runningNow: Int { lock.withLock { running } }
        var finishedCount: Int { lock.withLock { finished } }

        func began() {
            lock.withLock {
                running += 1
                peak = max(peak, running)
            }
            gate.notify()
        }

        func ended() {
            lock.withLock {
                running -= 1
                finished += 1
            }
            gate.notify()
        }
    }

    private func makeQueue(width: Int) -> BoundedWorkQueue {
        BoundedWorkQueue(
            width: width,
            queue: DispatchQueue(
                label: "test.bounded-work-\(UUID().uuidString)", attributes: .concurrent))
    }

    @Test("no more than the width run at once, and everything submitted still runs")
    func widthBoundsWhatRunsAtOnce() async throws {
        let width = 3
        let queue = makeQueue(width: width)
        let tally = RunTally()
        // Every job parks until the test releases it, which is what a blocking
        // header read does — so the jobs over the width can only be waiting.
        let release = DispatchSemaphore(value: 0)
        let jobCount = width * 4
        for _ in 0..<jobCount {
            queue.submit {
                tally.began()
                release.wait()
                tally.ended()
            }
        }

        try await tally.gate.wait { tally.runningNow == width }
        #expect(queue.runningCountForTesting == width)
        #expect(queue.waitingCountForTesting == jobCount - width)

        for _ in 0..<jobCount { release.signal() }
        try await tally.gate.wait { tally.finishedCount == jobCount }
        #expect(tally.concurrentPeak == width)
        #expect(queue.runningCountForTesting == 0)
        #expect(queue.waitingCountForTesting == 0)
    }

    @Test("jobs that never fill the width all run at once")
    func workUnderTheWidthIsNotSerialized() async throws {
        let queue = makeQueue(width: 4)
        let tally = RunTally()
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<3 {
            queue.submit {
                tally.began()
                release.wait()
                tally.ended()
            }
        }

        try await tally.gate.wait { tally.runningNow == 3 }
        for _ in 0..<3 { release.signal() }
        try await tally.gate.wait { tally.finishedCount == 3 }
        #expect(tally.concurrentPeak == 3)
    }

    /// The jobs a clipboard connection submits own a descriptor each and close
    /// it on the way out, so one dropped on the floor would leak it.
    @Test("every job submitted runs, however narrow the queue")
    func nothingSubmittedIsDropped() async throws {
        let queue = makeQueue(width: 1)
        let tally = RunTally()
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<8 {
            queue.submit {
                tally.began()
                release.wait()
                tally.ended()
            }
        }

        try await tally.gate.wait { tally.runningNow == 1 }
        for _ in 0..<8 { release.signal() }
        try await tally.gate.wait { tally.finishedCount == 8 }
        #expect(tally.concurrentPeak == 1)
    }
}
