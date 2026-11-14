import Foundation
import KernovaSynchronization
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ClipboardTransferReporter", .caseScoped)
@MainActor
struct ClipboardTransferReporterTests {
    /// A reporter whose dwell passes only when the test releases it from `clock`.
    private func makeReporter(clock: GatedEngineClock) -> ClipboardTransferReporter {
        ClipboardTransferReporter(clock: clock)
    }

    /// Releases the one dwell armed on `clock`, at the production interval, and
    /// waits for the reporter to go idle under it.
    private func passDwell(
        on clock: GatedEngineClock, of reporter: ClipboardTransferReporter
    ) async throws {
        let dwell = try #require(clock.parked.first)
        #expect(clock.parked.count == 1)
        #expect(dwell.seconds == ClipboardTransferReporter.dwellSeconds)
        let changed = AsyncGate()
        reporter.onReportChanged = { _ in changed.notify() }
        clock.release(dwell)
        try await changed.wait { reporter.report == .idle }
    }

    private func makeOperation(
        _ reporter: ClipboardTransferReporter,
        gesture: ClipboardTransferGesture = .paste,
        onCancelRequested: (@Sendable () -> Void)? = nil
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: gesture, direction: .inbound, peerName: "macOS TEST",
            // Nothing is driven through the operation itself here; a clock
            // nothing advances or releases keeps it from timing anything.
            revealDelay: 0, idleGap: 0, clock: GatedEngineClock(),
            onCancelRequested: onCancelRequested, reporter: reporter)
    }

    private func snapshot(
        bytes: UInt64, total: UInt64 = 100, gesture: ClipboardTransferGesture = .paste
    ) -> ClipboardProgressSnapshot {
        ClipboardProgressSnapshot(
            direction: .inbound, peerName: "macOS TEST", currentItemName: nil, filesCompleted: 0,
            fileCount: 1, bytesTransferred: bytes, totalBytes: total, bytesPerSecond: nil,
            secondsRemaining: nil, gesture: gesture, elapsedSeconds: 1)
    }

    /// The readout a surface would render, or `nil` when none is running.
    private func runningSnapshot(_ reporter: ClipboardTransferReporter)
        -> ClipboardProgressSnapshot?
    {
        guard case .running(let snapshot, _) = reporter.report else { return nil }
        return snapshot
    }

    private func finish(
        _ failure: ClipboardTransferFailure, gesture: ClipboardTransferGesture = .paste,
        at date: Date = Date()
    ) -> ClipboardTransferFinish {
        ClipboardTransferFinish(
            gesture: gesture, outcome: .failed(failure), peerName: "macOS TEST", date: date)
    }

    // MARK: - Running

    @Test("the newest running operation takes the readout, and the older one gets it back")
    func newestRunningWins() throws {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let first = makeOperation(reporter)
        let second = makeOperation(reporter)
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)

        reporter.publish(from: first, .running(snapshot(bytes: 10), since: early))
        reporter.publish(from: second, .running(snapshot(bytes: 20), since: late))
        guard case .running(let shown, let since) = reporter.report else {
            Issue.record("expected a running report")
            return
        }
        #expect(shown.bytesTransferred == 20)
        #expect(since == late)

        reporter.retire(second)
        guard case .running(let restored, _) = reporter.report else {
            Issue.record("expected the earlier operation's readout back")
            return
        }
        #expect(restored.bytesTransferred == 10)
    }

    // MARK: - Dwell

    @Test("a dwell armed for one report is defused by the next")
    func aNewReportDefusesTheDwell() async throws {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let operation = makeOperation(reporter)
        let completed = ClipboardTransferFinish(
            gesture: .paste, outcome: .completed(final: snapshot(bytes: 100)),
            peerName: "macOS TEST")

        reporter.publish(from: operation, .finished(completed))
        #expect(clock.parked.count == 1)
        let next = makeOperation(reporter)
        reporter.publish(from: next, .running(snapshot(bytes: 5), since: Date()))
        // The dwell armed for the completed report is called off, not left to
        // fire against the readout that replaced it.
        try await clock.parkedChanged.wait { clock.parked.isEmpty }

        guard case .running = reporter.report else {
            Issue.record("the stale dwell must not clear the newer readout")
            return
        }
    }

    // MARK: - A refusal raised alongside another operation

    @Test("a refusal raised during another operation survives that operation's completion")
    func refusalOutlivesAConcurrentOperation() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let preview = makeOperation(reporter, gesture: .preview)
        let since = Date(timeIntervalSince1970: 100)

        // A preview is on screen...
        reporter.publish(from: preview, .running(snapshot(bytes: 10), since: since))
        guard case .running = reporter.report else {
            Issue.record("expected the preview's readout")
            return
        }

        // ...when a paste fire fails underneath it. The refusal shows at once, so
        // the notice popover, the dropdown line and the window banner all fire.
        let refusal = finish(.diskFull(needed: 4096, available: 0), at: since.addingTimeInterval(1))
        reporter.finish(refusal)
        #expect(reporter.report == .finished(refusal))

        // The running operation's next emission takes the bar back; the refusal
        // stands underneath rather than being dropped.
        reporter.publish(from: preview, .running(snapshot(bytes: 20), since: since))
        guard case .running = reporter.report else {
            Issue.record("the running operation must take the readout back")
            return
        }

        // Running to the end says nothing about the paste that failed alongside,
        // so the completion must not clear it.
        reporter.publish(
            from: preview,
            .finished(
                ClipboardTransferFinish(
                    gesture: .preview, outcome: .completed(final: snapshot(bytes: 100)),
                    peerName: "macOS TEST")))
        #expect(reporter.report == .finished(refusal))
        // No dwell retires it either: a refusal stands until something displaces
        // it, and this one is not the dwell's to clear.
        #expect(clock.requestedSeconds.isEmpty)
    }

    @Test("a retry that succeeds clears a failure that stood before it began")
    func aLaterSuccessClearsAnOlderFailure() async throws {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let retry = makeOperation(reporter)
        let failedAt = Date(timeIntervalSince1970: 100)

        reporter.finish(finish(.transferFailed, at: failedAt))
        // The retry begins *after* the failure, so its completion disproves it.
        let since = failedAt.addingTimeInterval(1)
        reporter.publish(from: retry, .running(snapshot(bytes: 10), since: since))
        let completed = ClipboardTransferFinish(
            gesture: .paste, outcome: .completed(final: snapshot(bytes: 100)),
            peerName: "macOS TEST")
        reporter.publish(from: retry, .finished(completed))

        #expect(reporter.report == .finished(completed))
        try await passDwell(on: clock, of: reporter)
    }

    @Test("the peer's paste completing leaves this side's own refusal standing")
    func aPeerPasteDoesNotClearThisSidesRefusal() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let peerPaste = makeOperation(reporter, gesture: .peerPaste)
        let refusedAt = Date(timeIntervalSince1970: 100)

        // Passthrough could not forward every item this side's user copied, and
        // said so.
        let refusal = finish(
            .itemsSkipped(count: 1), gesture: .forward, at: refusedAt)
        reporter.finish(refusal)

        // The guest then pastes what did get across. Its bar takes the readout.
        let since = refusedAt.addingTimeInterval(1)
        reporter.publish(
            from: peerPaste, .running(snapshot(bytes: 10, gesture: .peerPaste), since: since))
        #expect(runningSnapshot(reporter)?.gesture == .peerPaste)

        // That paste answers the *guest's* user; it disproves nothing about the
        // items this side's copy left behind, however late it began.
        reporter.publish(
            from: peerPaste,
            .finished(
                ClipboardTransferFinish(
                    gesture: .peerPaste, outcome: .completed(final: snapshot(bytes: 100)),
                    peerName: "macOS TEST")))
        #expect(reporter.report == .finished(refusal))
        #expect(clock.requestedSeconds.isEmpty)
    }

    @Test("the peer's paste failing leaves this side's own refusal standing too")
    func aFailedPeerPasteDoesNotDisplaceThisSidesRefusal() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let peerPaste = makeOperation(reporter, gesture: .peerPaste)
        let refusedAt = Date(timeIntervalSince1970: 100)

        let refusal = finish(
            .itemsSkipped(count: 1), gesture: .forward, at: refusedAt)
        reporter.finish(refusal)

        // The guest pastes the file that did get across, and *that* transfer
        // fails. Its refusal is the guest user's — the surfaces that interrupt
        // here don't even present it — so it must not take the only message this
        // side's user has off the screen.
        let since = refusedAt.addingTimeInterval(1)
        reporter.publish(
            from: peerPaste, .running(snapshot(bytes: 10, gesture: .peerPaste), since: since))
        reporter.publish(
            from: peerPaste,
            .finished(finish(.transferFailed, gesture: .peerPaste, at: since.addingTimeInterval(1))))

        #expect(reporter.report == .finished(refusal))
        #expect(clock.requestedSeconds.isEmpty)
    }

    // MARK: - Absorbing repeats

    @Test("the repeated fires of one refused paste raise one report")
    func absorbsARepeatedRefusal() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        var changes = 0
        reporter.onReportChanged = { _ in changes += 1 }

        let first = finish(.transferFailed, at: Date(timeIntervalSince1970: 1))
        reporter.finish(first)
        reporter.finish(finish(.transferFailed, at: Date(timeIntervalSince1970: 2)))
        reporter.finish(finish(.transferFailed, at: Date(timeIntervalSince1970: 3)))

        #expect(changes == 1)
        #expect(reporter.report == .finished(first))
    }

    @Test("the same refusal after an operation ran in between is announced again")
    func reannouncesAfterARunningReport() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let operation = makeOperation(reporter)

        reporter.finish(finish(.transferFailed, at: Date(timeIntervalSince1970: 1)))
        reporter.publish(from: operation, .running(snapshot(bytes: 5), since: Date()))
        reporter.retire(operation)
        let later = finish(.transferFailed, at: Date(timeIntervalSince1970: 2))
        reporter.finish(later)

        #expect(reporter.report == .finished(later))
    }

    @Test("the same refusal from a later gesture is announced again, bar or no bar")
    func reannouncesAfterAnOperationThatOpenedNoBar() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        var announced: [ClipboardTransferFinish] = []
        reporter.onReportChanged = { report in
            guard case .finished(let finish) = report, finish.failure != nil else { return }
            announced.append(finish)
        }

        // One drop lost an item of its batch and said so.
        let first = makeOperation(reporter, gesture: .drop)
        reporter.queued(first)
        reporter.publish(
            from: first,
            .finished(
                finish(
                    .itemsSkipped(count: 1), gesture: .drop,
                    at: Date(timeIntervalSince1970: 1))))

        // The next drop ran to its end inside the reveal gate: it announced
        // itself as queued and retired without ever opening a bar.
        let quick = makeOperation(reporter, gesture: .drop)
        reporter.queued(quick)
        reporter.retire(quick)

        // A third drop loses an item of its own. It is a separate gesture over
        // separate files, so it is owed its own message rather than collapsed
        // into the one the first drop raised.
        let third = makeOperation(reporter, gesture: .drop)
        reporter.queued(third)
        let later = finish(
            .itemsSkipped(count: 1), gesture: .drop, at: Date(timeIntervalSince1970: 2))
        reporter.publish(from: third, .finished(later))

        #expect(reporter.report == .finished(later))
        #expect(announced.count == 2)
    }

    // MARK: - Surface entry points

    @Test("a cancel reaches the operation its readout named, not the newest one")
    func cancelReachesTheOperationItsReadoutNamed() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let olderStopped = Locked(false)
        let newerStopped = Locked(false)
        let older = makeOperation(reporter, onCancelRequested: { olderStopped.withLock { $0 = true } })
        let newer = makeOperation(reporter, onCancelRequested: { newerStopped.withLock { $0 = true } })

        reporter.publish(from: older, .running(snapshot(bytes: 1), since: Date()))
        reporter.publish(from: newer, .running(snapshot(bytes: 2), since: Date()))
        #expect(reporter.cancel(older.id))

        #expect(olderStopped.withLock { $0 })
        #expect(!newerStopped.withLock { $0 })
    }

    // MARK: - Ranking

    @Test("a preview fetch started during a drop leaves the drop on the readout")
    func aDropOutranksAPreviewStartedUnderIt() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let drop = makeOperation(reporter, gesture: .drop)
        let preview = makeOperation(reporter, gesture: .preview)

        reporter.publish(from: drop, .running(snapshot(bytes: 1, gesture: .drop), since: Date()))
        reporter.publish(
            from: preview, .running(snapshot(bytes: 2, gesture: .preview), since: Date()))

        #expect(runningSnapshot(reporter)?.gesture == .drop)
        // The fetch the ranking hides is still counted, so the queue reads as a
        // queue.
        #expect(runningSnapshot(reporter)?.pendingBehind == 1)
    }

    @Test("a queued operation takes the readout once it opens a bar of its own")
    func aQueuedOperationTakesTheReadoutWhenItStarts() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let waiting = makeOperation(reporter, gesture: .drop)
        let started = makeOperation(reporter, gesture: .drop)

        // The drop joins the live set when it is offered, so it is the *oldest*
        // entry while the peer is still busy with something offered after it.
        reporter.queued(waiting)
        reporter.publish(from: started, .running(snapshot(bytes: 1, gesture: .drop), since: Date()))
        #expect(runningSnapshot(reporter)?.bytesTransferred == 1)

        reporter.publish(from: waiting, .running(snapshot(bytes: 2, gesture: .drop), since: Date()))
        #expect(runningSnapshot(reporter)?.bytesTransferred == 2)
    }

    // MARK: - Work behind the readout

    @Test("a queued operation is counted on the readout rather than replacing it")
    func aQueuedOperationIsCountedOnTheReadout() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let running = makeOperation(reporter, gesture: .drop)
        let waiting = makeOperation(reporter, gesture: .drop)

        reporter.publish(from: running, .running(snapshot(bytes: 1, gesture: .drop), since: Date()))
        #expect(runningSnapshot(reporter)?.pendingBehind == 0)

        reporter.queued(waiting)
        #expect(runningSnapshot(reporter)?.bytesTransferred == 1)
        #expect(runningSnapshot(reporter)?.pendingBehind == 1)
    }

    @Test("an operation that started is counted behind the readout that outranks it")
    func aRunningOperationUnderTheReadoutIsCountedToo() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let paste = makeOperation(reporter, gesture: .peerPaste)
        let drop = makeOperation(reporter, gesture: .drop)

        reporter.publish(
            from: paste, .running(snapshot(bytes: 1, gesture: .peerPaste), since: Date()))
        reporter.publish(from: drop, .running(snapshot(bytes: 2, gesture: .drop), since: Date()))

        #expect(runningSnapshot(reporter)?.gesture == .peerPaste)
        #expect(runningSnapshot(reporter)?.pendingBehind == 1)
    }

    @Test("A copy that delivered all but some items is logged as partial; one that delivered nothing, as failed")
    func partialCopyIsLoggedAsPartial() {
        func line(_ failure: ClipboardTransferFailure) -> String? {
            ClipboardTransferFinish(gesture: .copy, outcome: .failed(failure), peerName: "macOS TEST").logLine
        }
        #expect(line(.itemsSkipped(count: 1)) == "copy from 'macOS TEST' was partial: itemsSkipped(count: 1)")
        #expect(line(.partsGone) == "copy from 'macOS TEST' was partial: partsGone")
        #expect(line(.itemsUnreadable) == "copy from 'macOS TEST' failed: itemsUnreadable")
        // A link's end that took back only part of a copy, and one that took back all of it.
        #expect(
            line(.disconnectedFilesRetracted) == "copy from 'macOS TEST' was partial: disconnectedFilesRetracted")
        #expect(line(.disconnectedCopyRetracted) == "copy from 'macOS TEST' failed: disconnectedCopyRetracted")
        // The same, the guest having withdrawn the copy.
        #expect(line(.withdrawnFilesRetracted) == "copy from 'macOS TEST' was partial: withdrawnFilesRetracted")
        #expect(line(.withdrawnCopyRetracted) == "copy from 'macOS TEST' failed: withdrawnCopyRetracted")
    }
}
