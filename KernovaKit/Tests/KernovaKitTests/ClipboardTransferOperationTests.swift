import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

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
        expectedItems: Int = 0
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: gesture, direction: direction, peerName: "macOS TEST",
            expectedBytes: expectedBytes, expectedItems: expectedItems, clock: clock, reporter: recorder.reporter)
    }

    // MARK: - Reveal gate

    @Test("a refusal inside the reveal gate is still reported")
    func failureInsideTheGateIsPublished() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)

        operation.unitBegan(id: 1, expectedBytes: 100)
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

        operation.unitBegan(id: 0, expectedBytes: 2_048)
        operation.unitEnded(id: 0, succeeded: true)
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

    @Test("a retry that restarts its own byte count never walks the aggregate back")
    func clampsMonotonically() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

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
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 1_000)
        operation.unitProgressed(id: 1, bytesTransferred: 400, totalBytes: 500)
        operation.finish(.completed)
        await settle()

        #expect(try #require(recorder.finish?.finalSnapshot).totalBytes == 500)
    }

    @Test("the readout names the transfer that began most recently")
    func tracksTheCurrentItemName() async {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100, name: "first.txt")
        operation.unitBegan(id: 2, expectedBytes: 100, name: "second.txt")
        operation.unitProgressed(id: 2, bytesTransferred: 50)
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
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

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
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

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
        let clock = GatedEngineClock()
        let operation = makeOperation(
            recorder: recorder, clock: clock, gesture: .peerPaste, direction: .outbound)
        clock.advance(seconds: Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.unitEnded(id: 1, succeeded: true)
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
        #expect(finish.gesture == .peerPaste)
        #expect(finish.finalSnapshot?.fractionComplete == 1)
    }

    @Test("an idle terminal whose gap passed as a transfer began completes nothing")
    func anIdleTerminalPassingAsATransferBeginsCompletesNothing() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(
            recorder: recorder, clock: clock, gesture: .peerPaste, direction: .outbound)
        clock.advance(seconds: Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.unitEnded(id: 1, succeeded: true)
        operation.finishWhenIdle()
        let gap = try #require(clock.parked.first)

        // The gap passes, and before the terminal takes the lock the peer's next
        // pull begins.
        clock.releaseHeld(gap)
        operation.unitBegan(id: 2, expectedBytes: 100)
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
            recorder: recorder, clock: clock, gesture: .peerPaste, direction: .outbound)
        clock.advance(seconds: Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.unitEnded(id: 1, succeeded: true)
        operation.finishWhenIdle()
        operation.unitBegan(id: 2, expectedBytes: 100)
        operation.unitEnded(id: 2, succeeded: true)
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

        operation?.unitBegan(id: 1, expectedBytes: 100)
        operation?.unitEnded(id: 1, succeeded: true)
        operation?.finishWhenIdle()
        await settle()
        #expect(recorder.runningSnapshot != nil)
        #expect(clock.parked.count == 1)

        // The reporter holds the operation weakly, so nothing else would ever
        // take this bar down.
        operation = nil
        try await recorder.changed.wait { recorder.latest == .idle }
    }
}
