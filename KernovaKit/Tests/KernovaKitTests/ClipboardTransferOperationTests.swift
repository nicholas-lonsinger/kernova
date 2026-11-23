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

    var finish: ClipboardTransferFinish? {
        guard case .finished(let finish) = latest else { return nil }
        return finish
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
        gesture: ClipboardTransferGesture = .paste,
        direction: ClipboardProgressSnapshot.Direction = .inbound,
        expectedBytes: UInt64? = 0,
        expectedItems: Int = 0
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: gesture, direction: direction, peerName: "macOS TEST",
            expectedBytes: expectedBytes, expectedItems: expectedItems, clock: clock, reporter: recorder.reporter)
    }

    // MARK: - Terminals

    @Test("a second terminal is dropped")
    func finishIsIdempotent() async throws {
        let recorder = Recorder()
        let clock = GatedEngineClock()
        let operation = makeOperation(recorder: recorder, clock: clock)
        clock.advance(seconds: Self.revealDelay)

        operation.unitBegan(id: 1, expectedBytes: 100)
        operation.finish(.failed(.timedOut))
        operation.finish(.completed)
        try await drainMainQueue()

        #expect(recorder.finish?.failure == .timedOut)
        #expect(!operation.isLive)
    }

    // MARK: - Idle terminal

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
        try await drainMainQueue()

        #expect(operation.isLive)
        #expect(recorder.finish == nil)
    }
}
