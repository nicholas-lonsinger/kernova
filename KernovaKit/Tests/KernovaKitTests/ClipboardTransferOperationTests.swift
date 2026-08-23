import Foundation
import Testing

@testable import KernovaKit

/// Manually advanced monotonic clock for an operation's `now` seam.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0

    var now: TimeInterval { lock.withLock { seconds } }

    func advance(_ interval: TimeInterval) {
        lock.withLock { seconds += interval }
    }
}

/// Captures the delayed work an operation arms, so a test fires the idle
/// terminal instead of waiting for it.
private final class TestScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []

    func schedule(after _: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        lock.withLock { pending.append(work) }
    }

    /// Runs everything armed so far.
    func fire() {
        let work = lock.withLock { () -> [@Sendable () -> Void] in
            let armed = pending
            pending.removeAll()
            return armed
        }
        work.forEach { $0() }
    }
}

/// One-shot flag a `@Sendable` cancel closure can set from any thread.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// Records every report an operation drives its reporter to.
@MainActor
private final class Recorder {
    let reporter: ClipboardTransferReporter
    private(set) var reports: [ClipboardTransferReport] = []

    /// The dwell never fires: a finished report stands for the whole test rather
    /// than retiring under it.
    init() {
        reporter = ClipboardTransferReporter(dwell: 0, schedule: { _, _ in })
        reporter.onReportChanged = { [weak self] report in self?.reports.append(report) }
    }

    var latest: ClipboardTransferReport { reports.last ?? .idle }

    var runningSnapshot: ClipboardProgressSnapshot? {
        guard case .running(let snapshot, _) = latest else { return nil }
        return snapshot
    }

    var finish: ClipboardTransferFinish? {
        guard case .finished(let finish) = latest else { return nil }
        return finish
    }
}

/// Returns once every main-queue block enqueued before this call has run.
///
/// An operation publishes through one serial `DispatchQueue.main.async` hop, so
/// this settles its readout deterministically — no deadline is the pass/fail
/// criterion and nothing polls.
@MainActor
private func settle() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@Suite("ClipboardTransferOperation", .admissionGated)
@MainActor
struct ClipboardTransferOperationTests {
    private static let revealDelay: TimeInterval = 0.3

    private func makeOperation(
        recorder: Recorder,
        clock: TestClock,
        scheduler: TestScheduler = TestScheduler(),
        gesture: ClipboardTransferGesture = .preview,
        direction: ClipboardProgressSnapshot.Direction = .inbound,
        expectedBytes: UInt64 = 0,
        expectedItems: Int = 0,
        onCancelRequested: (@Sendable () -> Void)? = nil
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: gesture, direction: direction, peerName: "macOS TEST",
            expectedBytes: expectedBytes, expectedItems: expectedItems,
            revealDelay: Self.revealDelay, idleGap: 2,
            now: { clock.now }, schedule: { after, work in scheduler.schedule(after: after, work) },
            onCancelRequested: onCancelRequested, reporter: recorder.reporter)
    }

    // MARK: - Reveal gate

    @Test("nothing reaches a surface until the operation has run for the reveal delay")
    func revealsOnlyAfterTheDelay() async {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.unitProgressed(id: 1, bytesTransferred: 50)
        await settle()
        #expect(recorder.reports.isEmpty)

        clock.advance(Self.revealDelay)
        operation.unitProgressed(id: 1, bytesTransferred: 60)
        await settle()
        #expect(recorder.runningSnapshot?.bytesTransferred == 60)
    }

    @Test("an operation that completes inside the reveal gate never flashes UI")
    func completionInsideTheGatePublishesNothing() async {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.unitEnded(id: 1, succeeded: true)
        operation.finish(.completed)
        await settle()
        #expect(recorder.reports.isEmpty)
    }

    @Test("a refusal inside the reveal gate is still reported")
    func failureInsideTheGateIsPublished() async {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.finish(.failed(.timedOut))
        await settle()
        #expect(recorder.finish?.failure == .timedOut)
    }

    // MARK: - Aggregation

    @Test("concurrent and sequential transfers fill one bar between them")
    func aggregatesEveryTransfer() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.unitBegan(id: 2, expectedBytes: 300)
        operation.unitProgressed(id: 1, bytesTransferred: 100)
        operation.unitEnded(id: 1, succeeded: true)
        operation.unitProgressed(id: 2, bytesTransferred: 300)
        operation.unitEnded(id: 2, succeeded: true)
        operation.finish(.completed)
        await settle()

        let snapshot = try #require(recorder.finish?.finalSnapshot)
        #expect(snapshot.totalBytes == 400)
        #expect(snapshot.bytesTransferred == 400)
        #expect(snapshot.filesCompleted == 2)
        #expect(snapshot.fileCount == 2)
    }

    @Test("a retry that restarts its own byte count never walks the aggregate back")
    func clampsMonotonically() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 1_000)
        operation.unitProgressed(id: 1, bytesTransferred: 800)
        operation.unitProgressed(id: 1, bytesTransferred: 0)
        operation.finish(.completed)
        await settle()

        #expect(try #require(recorder.finish?.finalSnapshot).bytesTransferred == 800)
    }

    @Test("the streamed total replaces what the transfer advertised")
    func totalIsWireAuthoritative() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 1_000)
        operation.unitProgressed(id: 1, bytesTransferred: 400, totalBytes: 500)
        operation.finish(.completed)
        await settle()

        #expect(try #require(recorder.finish?.finalSnapshot).totalBytes == 500)
    }

    @Test("a transfer that succeeded reads as complete even with its last chunks throttled")
    func creditsSuccessInFull() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 1_000)
        operation.unitProgressed(id: 1, bytesTransferred: 10)
        operation.unitEnded(id: 1, succeeded: true)
        operation.finish(.completed)
        await settle()

        let snapshot = try #require(recorder.finish?.finalSnapshot)
        #expect(snapshot.bytesTransferred == 1_000)
        #expect(snapshot.fractionComplete == 1)
    }

    @Test("the update that reaches the total is admitted however small its delta")
    func admitsTheFinalChunk() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 1_000)
        operation.unitProgressed(id: 1, bytesTransferred: 999)
        await settle()
        let beforeFinalChunk = recorder.reports.count
        operation.unitProgressed(id: 1, bytesTransferred: 1_000)
        await settle()

        #expect(recorder.reports.count == beforeFinalChunk + 1)
        #expect(try #require(recorder.runningSnapshot).fractionComplete == 1)
    }

    @Test("the readout names the transfer that began most recently")
    func tracksTheCurrentItemName() async {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100, name: "first.txt")
        operation.unitBegan(id: 2, expectedBytes: 100, name: "second.txt")
        operation.unitProgressed(id: 2, bytesTransferred: 50)
        await settle()

        #expect(recorder.runningSnapshot?.currentItemName == "second.txt")
    }

    @Test("the declared totals are a floor the transfers revise upward")
    func floorDenominatorIsRevisedUpward() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(
            recorder: recorder, clock: clock, expectedBytes: 500, expectedItems: 3)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        await settle()
        // One transfer of the three has begun: the whole drop is the denominator.
        #expect(recorder.runningSnapshot?.totalBytes == 500)
        #expect(recorder.runningSnapshot?.fileCount == 3)

        operation.unitBegan(id: 2, expectedBytes: 400)
        operation.unitBegan(id: 3, expectedBytes: 400)
        operation.unitBegan(id: 4, expectedBytes: 100)
        operation.finish(.completed)
        await settle()

        let snapshot = try #require(recorder.finish?.finalSnapshot)
        #expect(snapshot.totalBytes == 1_000)
        #expect(snapshot.fileCount == 4)
    }

    // MARK: - Terminals

    @Test("a chunk landing after the terminal cannot resurrect the readout")
    func dropsEventsAfterFinishing() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 1_000)
        operation.unitProgressed(id: 1, bytesTransferred: 300)
        operation.finish(.cancelled)
        await settle()
        let settled = recorder.reports.count

        operation.unitProgressed(id: 1, bytesTransferred: 900)
        operation.unitEnded(id: 1, succeeded: true)
        await settle()

        #expect(recorder.reports.count == settled)
        let finish = try #require(recorder.finish)
        // Cancelled below 100 %, at the fraction it stopped on, by design.
        #expect(finish.finalSnapshot?.bytesTransferred == 300)
        if case .cancelled = finish.outcome {} else { Issue.record("expected a cancelled outcome") }
    }

    @Test("a second terminal is dropped")
    func finishIsIdempotent() async {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.finish(.failed(.timedOut))
        operation.finish(.completed)
        await settle()

        #expect(recorder.finish?.failure == .timedOut)
        #expect(!operation.isLive)
    }

    @Test("a teardown retires the readout without reporting a finish")
    func abandonPublishesNothingFurther() async {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        await settle()
        #expect(recorder.runningSnapshot != nil)

        operation.abandon()
        await settle()
        #expect(recorder.latest == .idle)
        #expect(!operation.isLive)
    }

    // MARK: - Idle terminal

    @Test("the idle gap completes a peer-driven operation once nothing is in flight")
    func idleGapCompletesThePeerDrivenOperation() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let scheduler = TestScheduler()
        let operation = makeOperation(
            recorder: recorder, clock: clock, scheduler: scheduler, gesture: .peerPaste,
            direction: .outbound)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.unitEnded(id: 1, succeeded: true)
        operation.finishWhenIdle()
        await settle()
        // Still running: the gap is what tells the end from the pause between two
        // of the peer's pulls.
        #expect(recorder.finish == nil)

        scheduler.fire()
        await settle()
        let finish = try #require(recorder.finish)
        #expect(finish.gesture == .peerPaste)
        #expect(finish.finalSnapshot?.fractionComplete == 1)
    }

    @Test("a transfer beginning inside the gap defuses the idle terminal")
    func aNewTransferDefusesTheIdleTerminal() async {
        let recorder = Recorder()
        let clock = TestClock()
        let scheduler = TestScheduler()
        let operation = makeOperation(
            recorder: recorder, clock: clock, scheduler: scheduler, gesture: .peerPaste,
            direction: .outbound)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.unitEnded(id: 1, succeeded: true)
        operation.finishWhenIdle()
        operation.unitBegan(id: 2, expectedBytes: 100)
        scheduler.fire()
        await settle()

        #expect(operation.isLive)
        #expect(recorder.finish == nil)
    }

    // MARK: - Cancel

    @Test("a cancel on the readout reaches the operation's own stop closure")
    func routesCancelToTheOperation() {
        let recorder = Recorder()
        let clock = TestClock()
        let stopped = AtomicFlag()
        let operation = makeOperation(
            recorder: recorder, clock: clock, onCancelRequested: { stopped.set() })

        operation.requestCancel()
        #expect(stopped.value)
    }

    @Test("an operation with nothing to stop offers no cancel")
    func reportsWhetherItIsCancellable() async {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        await settle()
        #expect(recorder.runningSnapshot?.isCancellable == false)
        // A no-op rather than a crash for a caller that asks anyway.
        operation.requestCancel()
    }

    // MARK: - Queued

    @Test("an operation announced as queued shows no bar of its own")
    func queuedShowsNoBar() async {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock, gesture: .drop)

        operation.markQueued()
        await settle()

        // Nothing has begun, so there is nothing to draw — the reporter counts it
        // behind whatever readout is on screen instead.
        #expect(recorder.latest == .idle)
        withExtendedLifetime(operation) {}
    }

    @Test("a queued operation that ends without ever revealing leaves nothing behind")
    func queuedOperationRetiresOnItsTerminal() async {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock, gesture: .drop)

        operation.markQueued()
        await settle()
        operation.finish(.completed)
        await settle()

        #expect(recorder.latest == .idle)
        #expect(recorder.finish == nil)
    }

    @Test("the readout takes over from the queued announcement once bytes move")
    func queuedGivesWayToTheReadout() async {
        let recorder = Recorder()
        let clock = TestClock()
        let operation = makeOperation(recorder: recorder, clock: clock, gesture: .drop)

        operation.markQueued()
        clock.advance(Self.revealDelay)
        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.unitProgressed(id: 1, bytesTransferred: 40)
        await settle()

        #expect(recorder.runningSnapshot?.bytesTransferred == 40)
        #expect(recorder.runningSnapshot?.pendingBehind == 0)
    }
}
