import Foundation
import KernovaSynchronization
import KernovaTestSupport
import Testing

@testable import KernovaKit
@testable import KernovaTransferProgress

/// Records every report an operation drives its reporter to.
@MainActor
private final class Recorder {
    let reporter: ClipboardTransferReporter
    private(set) var reports: [ClipboardTransferReport] = []
    /// Notified on each report, for an event-driven wait.
    let changed = AsyncGate()

    /// The dwell is never released: a finished report stands for the whole test
    /// rather than retiring under it.
    init() {
        reporter = ClipboardTransferReporter(clock: GatedEngineClock())
        reporter.onReportChanged = { [weak self] report in
            self?.reports.append(report)
            self?.changed.notify()
        }
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

@Suite("ClipboardTransferOperation", .caseScoped)
@MainActor
struct ClipboardTransferOperationTests {
    private static let revealDelay = ClipboardTransferOperation.defaultRevealDelay

    /// An operation at the production reveal delay and idle gap, measured on
    /// `clock` — whose reading moves only when the test advances it, and whose
    /// idle terminal passes only when the test releases it.
    private func makeOperation(
        recorder: Recorder,
        clock: GatedEngineClock,
        gesture: ClipboardTransferGesture = .preview,
        direction: ClipboardProgressSnapshot.Direction = .inbound,
        expectedBytes: UInt64? = 0,
        expectedItems: Int = 0,
        onCancelRequested: (@Sendable () -> Void)? = nil
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: gesture, direction: direction, peerName: "macOS TEST",
            expectedBytes: expectedBytes, expectedItems: expectedItems, clock: clock,
            onCancelRequested: onCancelRequested, reporter: recorder.reporter)
    }

    // MARK: - Reveal gate

    @Test("nothing reaches a surface until the operation has run for the reveal delay")
    func revealsOnlyAfterTheDelay() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)

        let unit1 = operation.unit(expectedBytes: 100)
        unit1?.advanced(landed: 50, declared: 0)
        await settle()
        #expect(recorder.reports.isEmpty)

        clock.advance(seconds: Self.revealDelay)
        unit1?.advanced(landed: 60, declared: 0)
        await settle()
        #expect(recorder.runningSnapshot?.bytesTransferred == 60)
    }

    @Test("an operation that completes inside the reveal gate never flashes UI")
    func completionInsideTheGatePublishesNothing() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)

        let unit1 = operation.unit(expectedBytes: 100)
        unit1?.ended(succeeded: true)
        operation.finish(.completed)
        await settle()
        #expect(recorder.reports.isEmpty)
    }

    @Test("a refusal inside the reveal gate is still reported")
    func failureInsideTheGateIsPublished() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)

        _ = operation.unit(expectedBytes: 100)
        operation.finish(.failed(.timedOut))
        await settle()
        #expect(recorder.finish?.failure == .timedOut)
    }

    // MARK: - Unknown bytes

    @Test("an operation that cannot know its bytes counts its files, and says nothing of bytes")
    func unknownBytesCountFiles() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(
            recorder: recorder, clock: clock, gesture: .dragOut, expectedBytes: nil, expectedItems: 4)
        clock.advance(seconds: Self.revealDelay)

        let unit0 = operation.unit(expectedBytes: 2_048)
        unit0?.ended(succeeded: true)
        await settle()
        let running = try #require(recorder.runningSnapshot)
        #expect(!running.bytesKnown)
        #expect(running.bytesTransferred == 0)
        #expect(running.totalBytes == 0)
        #expect(running.filesCompleted == 1)
        #expect(running.fileCount == 4)
        #expect(running.fractionComplete == 0.25)
        #expect(running.bytesPerSecond == nil)
        #expect(running.secondsRemaining == nil)
        #expect(ClipboardProgressFormat.byteProgress(running) == nil)
    }

    // MARK: - Aggregation

    @Test("concurrent and sequential transfers fill one bar between them")
    func aggregatesEveryTransfer() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        let unit1 = operation.unit(expectedBytes: 100)
        let unit2 = operation.unit(expectedBytes: 300)
        unit1?.advanced(landed: 100, declared: 0)
        unit1?.ended(succeeded: true)
        unit2?.advanced(landed: 300, declared: 0)
        unit2?.ended(succeeded: true)
        operation.finish(.completed)
        await settle()

        let snapshot = try #require(recorder.finish?.finalSnapshot)
        #expect(snapshot.totalBytes == 400)
        #expect(snapshot.bytesTransferred == 400)
        #expect(snapshot.filesCompleted == 2)
        #expect(snapshot.fileCount == 2)
    }

    @Test("a landing report below an earlier one never walks the aggregate back")
    func clampsMonotonically() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        let unit1 = operation.unit(expectedBytes: 1_000)
        unit1?.advanced(landed: 800, declared: 0)
        unit1?.advanced(landed: 0, declared: 0)
        operation.finish(.completed)
        await settle()

        #expect(try #require(recorder.finish?.finalSnapshot).bytesTransferred == 800)
    }

    @Test("what a landing declares raises its transfer's estimate and never lowers it")
    func declaredRaisesTheEstimate() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        let overEstimated = operation.unit(expectedBytes: 1_000)
        let underEstimated = operation.unit(expectedBytes: 100)
        overEstimated?.advanced(landed: 400, declared: 500)
        underEstimated?.advanced(landed: 50, declared: 300)
        operation.finish(.completed)
        await settle()

        let snapshot = try #require(recorder.finish?.finalSnapshot)
        #expect(snapshot.totalBytes == 1_300)
        #expect(snapshot.bytesTransferred == 450)
    }

    @Test("what a landing reports after its owner ended the transfer is not counted")
    func dropsLandingReportsAfterTheEnd() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        let unit = operation.unit(expectedBytes: 1_000)
        unit?.advanced(landed: 300, declared: 1_000)
        unit?.ended(succeeded: false)
        // The pull's lane drains what it was handed before the abort.
        unit?.advanced(landed: 900, declared: 1_000)
        operation.finish(.completed)
        await settle()

        let snapshot = try #require(recorder.finish?.finalSnapshot)
        #expect(snapshot.bytesTransferred == 300)
        #expect(snapshot.filesCompleted == 0)
    }

    @Test("a transfer that succeeded reads as complete even with its last chunks throttled")
    func creditsSuccessInFull() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        let unit1 = operation.unit(expectedBytes: 1_000)
        unit1?.advanced(landed: 10, declared: 0)
        unit1?.ended(succeeded: true)
        operation.finish(.completed)
        await settle()

        let snapshot = try #require(recorder.finish?.finalSnapshot)
        #expect(snapshot.bytesTransferred == 1_000)
        #expect(snapshot.fractionComplete == 1)
    }

    @Test("the update that reaches the total is admitted however small its delta")
    func admitsTheFinalChunk() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        let unit1 = operation.unit(expectedBytes: 1_000)
        unit1?.advanced(landed: 999, declared: 0)
        await settle()
        let beforeFinalChunk = recorder.reports.count
        unit1?.advanced(landed: 1_000, declared: 0)
        await settle()

        #expect(recorder.reports.count == beforeFinalChunk + 1)
        #expect(try #require(recorder.runningSnapshot).fractionComplete == 1)
    }

    @Test("the readout names the transfer that began most recently")
    func tracksTheCurrentItemName() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        _ = operation.unit(name: "first.txt", expectedBytes: 100)
        let unit2 = operation.unit(name: "second.txt", expectedBytes: 100)
        unit2?.advanced(landed: 50, declared: 0)
        await settle()

        #expect(recorder.runningSnapshot?.currentItemName == "second.txt")
    }

    @Test("the declared totals are a floor the transfers revise upward")
    func floorDenominatorIsRevisedUpward() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(
            recorder: recorder, clock: clock, expectedBytes: 500, expectedItems: 3)
        clock.advance(seconds: Self.revealDelay)

        _ = operation.unit(expectedBytes: 100)
        await settle()
        // One transfer of the three has begun: the whole drop is the denominator.
        #expect(recorder.runningSnapshot?.totalBytes == 500)
        #expect(recorder.runningSnapshot?.fileCount == 3)

        _ = operation.unit(expectedBytes: 400)
        _ = operation.unit(expectedBytes: 400)
        _ = operation.unit(expectedBytes: 100)
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
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        let unit1 = operation.unit(expectedBytes: 1_000)
        unit1?.advanced(landed: 300, declared: 0)
        operation.finish(.cancelled)
        await settle()
        let settled = recorder.reports.count

        unit1?.advanced(landed: 900, declared: 0)
        unit1?.ended(succeeded: true)
        await settle()

        #expect(recorder.reports.count == settled)
        let finish = try #require(recorder.finish)
        // Cancelled below 100 %, at the fraction it stopped on.
        #expect(finish.finalSnapshot?.bytesTransferred == 300)
        if case .cancelled = finish.outcome {} else { Issue.record("expected a cancelled outcome") }
    }

    @Test("a second terminal is dropped")
    func finishIsIdempotent() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        _ = operation.unit(expectedBytes: 100)
        operation.finish(.failed(.timedOut))
        operation.finish(.completed)
        await settle()

        #expect(recorder.finish?.failure == .timedOut)
        #expect(!operation.isLive)
    }

    @Test("a teardown retires the readout without reporting a finish")
    func abandonPublishesNothingFurther() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        _ = operation.unit(expectedBytes: 100)
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
        let clock = GatedEngineClock()
        let operation = makeOperation(
            recorder: recorder, clock: clock, gesture: .paste)
        clock.advance(seconds: Self.revealDelay)

        let unit1 = operation.unit(expectedBytes: 100)
        unit1?.ended(succeeded: true)
        operation.finishWhenIdle()
        await settle()
        // Still running: the gap is what tells the end from the pause between two
        // of the peer's pulls.
        #expect(recorder.finish == nil)
        let gap = try #require(clock.parked.first)
        #expect(gap.seconds == ClipboardTransferOperation.defaultIdleGap)

        clock.release(gap)
        try await recorder.changed.wait { recorder.finish != nil }
        let finish = try #require(recorder.finish)
        #expect(finish.gesture == .paste)
        #expect(finish.finalSnapshot?.fractionComplete == 1)
    }

    @Test("a transfer beginning inside the gap defuses the idle terminal")
    func aNewTransferDefusesTheIdleTerminal() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(
            recorder: recorder, clock: clock, gesture: .paste)
        clock.advance(seconds: Self.revealDelay)

        let unit1 = operation.unit(expectedBytes: 100)
        unit1?.ended(succeeded: true)
        operation.finishWhenIdle()
        #expect(clock.parked.count == 1)

        // The terminal armed for that gap is called off, not left to fire.
        _ = operation.unit(expectedBytes: 100)
        try await clock.parkedChanged.wait { clock.parked.isEmpty }
        await settle()

        #expect(operation.isLive)
        #expect(recorder.finish == nil)
    }

    @Test("an idle terminal whose gap passed as a transfer began completes nothing")
    func anIdleTerminalPassingAsATransferBeginsCompletesNothing() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(
            recorder: recorder, clock: clock, gesture: .paste)
        clock.advance(seconds: Self.revealDelay)

        let unit1 = operation.unit(expectedBytes: 100)
        unit1?.ended(succeeded: true)
        operation.finishWhenIdle()
        let gap = try #require(clock.parked.first)

        // The gap passes, and before the terminal takes the lock the peer's next
        // pull begins.
        clock.releaseHeld(gap)
        _ = operation.unit(expectedBytes: 100)
        clock.resume(gap)
        await clock.completion(of: gap)
        await settle()

        #expect(operation.isLive)
        #expect(recorder.finish == nil)
    }

    @Test("the idle gap restarts from the transfer that ended last")
    func theIdleGapFollowsTheLastTransfer() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(
            recorder: recorder, clock: clock, gesture: .paste)
        clock.advance(seconds: Self.revealDelay)

        let unit1 = operation.unit(expectedBytes: 100)
        unit1?.ended(succeeded: true)
        operation.finishWhenIdle()
        let unit2 = operation.unit(expectedBytes: 100)
        unit2?.ended(succeeded: true)
        operation.finishWhenIdle()
        try await clock.parkedChanged.wait { clock.parked.count == 1 }

        // The one gap left standing is the second transfer's.
        #expect(clock.requestedSeconds.count == 2)
        clock.release(try #require(clock.parked.first))
        try await recorder.changed.wait { recorder.finish != nil }
        #expect(recorder.finish?.finalSnapshot?.filesCompleted == 2)
    }

    @Test("an operation let go of before its idle gap passes takes its bar down with it")
    func anOperationLetGoOfRetiresItsReadout() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        var operation: ClipboardTransferOperation? = makeOperation(
            recorder: recorder, clock: clock, gesture: .dragOut, direction: .outbound)
        clock.advance(seconds: Self.revealDelay)

        let unit1 = operation?.unit(expectedBytes: 100)
        unit1?.ended(succeeded: true)
        operation?.finishWhenIdle()
        await settle()
        #expect(recorder.runningSnapshot != nil)
        #expect(clock.parked.count == 1)

        // The reporter holds the operation weakly, so nothing else would ever
        // take this bar down.
        operation = nil
        try await recorder.changed.wait { recorder.latest == .idle }
    }

    // MARK: - Cancel

    @Test("a cancel on the readout reaches the operation's own stop closure")
    func routesCancelToTheOperation() {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let stopped = Locked(false)
        let operation = makeOperation(
            recorder: recorder, clock: clock, onCancelRequested: { stopped.withLock { $0 = true } })
        let unit = operation.unit(expectedBytes: 100)

        #expect(operation.requestCancel())
        #expect(stopped.withLock { $0 })
        unit?.ended(succeeded: false)
    }

    @Test("Cancel is offered only while a transfer is in flight, and with none it stops nothing")
    func cancelOnlyWhileATransferIsInFlight() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let stops = Locked(0)
        let operation = makeOperation(
            recorder: recorder, clock: clock, gesture: .paste,
            onCancelRequested: { stops.withLock { $0 += 1 } })
        #expect(!operation.isCancellable)
        clock.advance(seconds: Self.revealDelay)

        let unit = try #require(operation.unit(expectedBytes: 100))
        unit.advanced(landed: 100, declared: 100)
        await settle()
        #expect(try #require(recorder.runningSnapshot).isCancellable)

        // The file landed whole: what the readout shows of its bytes does not move, but its Cancel goes.
        unit.ended(succeeded: true)
        await settle()
        let idle = try #require(recorder.runningSnapshot)
        #expect(idle.bytesTransferred == 100)
        #expect(!idle.isCancellable)
        #expect(!operation.requestCancel())
        #expect(!recorder.reporter.cancel(operation.id))
        #expect(stops.withLock { $0 } == 0)

        // The next file of the same paste brings it back.
        let next = try #require(operation.unit(expectedBytes: 100))
        await settle()
        #expect(try #require(recorder.runningSnapshot).isCancellable)
        #expect(recorder.reporter.cancel(operation.id))
        #expect(stops.withLock { $0 } == 1)
        next.ended(succeeded: false)
    }

    @Test("an operation with nothing to stop offers no cancel")
    func reportsWhetherItIsCancellable() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        _ = operation.unit(expectedBytes: 100)
        await settle()
        #expect(recorder.runningSnapshot?.isCancellable == false)
        // A no-op rather than a crash for a caller that asks anyway.
        operation.requestCancel()
    }

    // MARK: - Queued

    @Test("a queued operation that ends without ever revealing leaves nothing behind")
    func queuedOperationRetiresOnItsTerminal() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock, gesture: .drop)

        operation.markQueued()
        await settle()
        #expect(recorder.latest == .idle)
        operation.finish(.completed)
        await settle()

        #expect(recorder.latest == .idle)
        #expect(recorder.finish == nil)
    }

    @Test("the readout takes over from the queued announcement once bytes move")
    func queuedGivesWayToTheReadout() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock, gesture: .drop)

        operation.markQueued()
        clock.advance(seconds: Self.revealDelay)
        let unit1 = operation.unit(expectedBytes: 100)
        unit1?.advanced(landed: 40, declared: 0)
        await settle()

        #expect(recorder.runningSnapshot?.bytesTransferred == 40)
        #expect(recorder.runningSnapshot?.pendingBehind == 0)
    }
}
