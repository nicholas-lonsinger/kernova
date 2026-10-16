import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// One-shot flag a `@Sendable` cancel closure can set from any thread.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

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

    @Test("a running report displaces a standing refusal, and its finish takes over again")
    func runningAndFinishedDisplaceEachOther() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let operation = makeOperation(reporter)
        let standing = finish(.timedOut)

        reporter.finish(standing)
        #expect(reporter.report == .finished(standing))

        reporter.publish(from: operation, .running(snapshot(bytes: 5), since: Date()))
        guard case .running = reporter.report else {
            Issue.record("a running operation must displace the standing refusal")
            return
        }

        let ended = finish(.transferFailed)
        reporter.publish(from: operation, .finished(ended))
        #expect(reporter.report == .finished(ended))
    }

    // MARK: - Dwell

    @Test("a completed report dwells, then the reporter goes idle")
    func completedReportsDwellThenClear() async throws {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let operation = makeOperation(reporter)
        let completed = ClipboardTransferFinish(
            gesture: .paste, outcome: .completed(final: snapshot(bytes: 100)),
            peerName: "macOS TEST")

        reporter.publish(from: operation, .finished(completed))
        #expect(reporter.report == .finished(completed))

        try await passDwell(on: clock, of: reporter)
    }

    @Test("a refusal never dwells — it stands until something displaces or clears it")
    func failedReportsStand() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)

        reporter.finish(finish(.timedOut))
        #expect(clock.requestedSeconds.isEmpty)
        guard case .finished = reporter.report else {
            Issue.record("expected the refusal to stand")
            return
        }

        reporter.clearFinished()
        #expect(reporter.report == .idle)
    }

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

    @Test("a dwell whose interval passed as the report changed retires nothing")
    func aDwellPassingAsTheReportChangesRetiresNothing() async throws {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let operation = makeOperation(reporter)
        let completed = ClipboardTransferFinish(
            gesture: .paste, outcome: .completed(final: snapshot(bytes: 100)),
            peerName: "macOS TEST")
        reporter.publish(from: operation, .finished(completed))
        let dwell = try #require(clock.parked.first)

        // The interval passes, and before the dwell's body can reach the main
        // actor a refusal replaces the report it was armed for.
        clock.release(dwell)
        let refusal = finish(.timedOut)
        reporter.finish(refusal)
        await clock.completion(of: dwell)

        #expect(reporter.report == .finished(refusal))
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
            .itemsSkipped(note: "Skipped 1 unreadable item"), gesture: .forward, at: refusedAt)
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
            .itemsSkipped(note: "Skipped 1 unreadable item"), gesture: .forward, at: refusedAt)
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

    @Test("a peer paste that succeeds still clears the peer paste that failed before it")
    func aPeerPasteClearsAnOlderPeerPasteRefusal() async throws {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let retry = makeOperation(reporter, gesture: .peerPaste)
        let failedAt = Date(timeIntervalSince1970: 100)

        // The guest's first paste failed; the refusal is the guest user's.
        reporter.finish(finish(.transferFailed, gesture: .peerPaste, at: failedAt))
        // Their retry begins after it and runs to the end, so it disproves it.
        let since = failedAt.addingTimeInterval(1)
        reporter.publish(
            from: retry, .running(snapshot(bytes: 10, gesture: .peerPaste), since: since))
        let completed = ClipboardTransferFinish(
            gesture: .peerPaste, outcome: .completed(final: snapshot(bytes: 100)),
            peerName: "macOS TEST")
        reporter.publish(from: retry, .finished(completed))

        #expect(reporter.report == .finished(completed))
        try await passDwell(on: clock, of: reporter)
    }

    // MARK: - Absorbing repeats

    @Test("the repeated fires of one refused paste raise one report")
    func absorbsARepeatedRefusal() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        var changes = 0
        reporter.onReportChanged = { _ in changes += 1 }

        let first = finish(.incompleteFileSet, at: Date(timeIntervalSince1970: 1))
        reporter.finish(first)
        reporter.finish(finish(.incompleteFileSet, at: Date(timeIntervalSince1970: 2)))
        reporter.finish(finish(.incompleteFileSet, at: Date(timeIntervalSince1970: 3)))

        #expect(changes == 1)
        #expect(reporter.report == .finished(first))
    }

    @Test("the same refusal after an operation ran in between is announced again")
    func reannouncesAfterARunningReport() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let operation = makeOperation(reporter)

        reporter.finish(finish(.incompleteFileSet, at: Date(timeIntervalSince1970: 1)))
        reporter.publish(from: operation, .running(snapshot(bytes: 5), since: Date()))
        reporter.retire(operation)
        let later = finish(.incompleteFileSet, at: Date(timeIntervalSince1970: 2))
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

    @Test("a gesture that opens no operation at all is still owed its own message")
    func reannouncesAfterAGestureThatOpenedNoOperation() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        var announced: [ClipboardTransferFinish] = []
        reporter.onReportChanged = { report in
            guard case .finished(let finish) = report, finish.failure != nil else { return }
            announced.append(finish)
        }

        // A drag whose items were all unreadable: nothing was offered, so no
        // operation ever measured it.
        reporter.gestureBegan()
        reporter.finish(
            finish(.itemsUnreadable, gesture: .drop, at: Date(timeIntervalSince1970: 1)))

        // The next drag fails the same way. It is a separate gesture, so the
        // same sentence is owed again rather than collapsed into the first.
        reporter.gestureBegan()
        let later = finish(.itemsUnreadable, gesture: .drop, at: Date(timeIntervalSince1970: 2))
        reporter.finish(later)

        #expect(reporter.report == .finished(later))
        #expect(announced.count == 2)
    }

    // MARK: - Surface entry points

    @Test("clearing a finished report leaves a running one alone")
    func clearFinishedLeavesRunningAlone() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let operation = makeOperation(reporter)

        reporter.publish(from: operation, .running(snapshot(bytes: 5), since: Date()))
        reporter.clearFinished()
        guard case .running = reporter.report else {
            Issue.record("expected the running readout to survive")
            return
        }
    }

    @Test("a cancel reaches the operation its readout named, not the newest one")
    func cancelReachesTheOperationItsReadoutNamed() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let olderStopped = AtomicFlag()
        let newerStopped = AtomicFlag()
        let older = makeOperation(reporter, onCancelRequested: { olderStopped.set() })
        let newer = makeOperation(reporter, onCancelRequested: { newerStopped.set() })

        reporter.publish(from: older, .running(snapshot(bytes: 1), since: Date()))
        reporter.publish(from: newer, .running(snapshot(bytes: 2), since: Date()))
        #expect(reporter.cancel(older.id))

        #expect(olderStopped.value)
        #expect(!newerStopped.value)
    }

    @Test("a cancel of an operation that cannot be stopped reaches nothing else")
    func cancelOfANonCancellableOperationStopsNothing() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let stopped = AtomicFlag()
        let cancellable = makeOperation(reporter, onCancelRequested: { stopped.set() })
        // A paste fire: the pasteboard drives it one item at a time, so there is
        // nothing a Cancel could usefully stop.
        let pasteFire = makeOperation(reporter)

        reporter.publish(from: cancellable, .running(snapshot(bytes: 1), since: Date()))
        reporter.publish(from: pasteFire, .running(snapshot(bytes: 2), since: Date()))

        #expect(!reporter.cancel(pasteFire.id))
        #expect(!stopped.value)
    }

    @Test("a cancel for an operation that has ended reports it reached nothing")
    func cancelOfAFinishedOperationIsANoOp() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let stopped = AtomicFlag()
        let operation = makeOperation(reporter, onCancelRequested: { stopped.set() })

        reporter.publish(from: operation, .running(snapshot(bytes: 1), since: Date()))
        reporter.publish(
            from: operation,
            .finished(
                ClipboardTransferFinish(
                    gesture: .drop, outcome: .completed(final: snapshot(bytes: 1)),
                    peerName: "macOS TEST")))

        #expect(!reporter.cancel(operation.id))
        #expect(!stopped.value)
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

    @Test("equal-ranked operations keep the newest readout")
    func equalRanksFallBackToRecency() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let older = makeOperation(reporter, gesture: .drop)
        let newer = makeOperation(reporter, gesture: .drop)

        reporter.publish(from: older, .running(snapshot(bytes: 1, gesture: .drop), since: Date()))
        reporter.publish(from: newer, .running(snapshot(bytes: 2, gesture: .drop), since: Date()))

        #expect(runningSnapshot(reporter)?.bytesTransferred == 2)
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

    @Test("progress on the older of two running readouts does not take the bar back")
    func progressOnAnOlderReadoutDoesNotTakeTheBarBack() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let older = makeOperation(reporter, gesture: .drop)
        let newer = makeOperation(reporter, gesture: .drop)

        reporter.publish(from: older, .running(snapshot(bytes: 1, gesture: .drop), since: Date()))
        reporter.publish(from: newer, .running(snapshot(bytes: 2, gesture: .drop), since: Date()))
        // Both are streaming: without this the bar would change hands on every
        // tick, since each publication would be the most recent one.
        reporter.publish(from: older, .running(snapshot(bytes: 9, gesture: .drop), since: Date()))

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

    @Test("a queued operation alone shows nothing — there is no bar to show yet")
    func aQueuedOperationAloneShowsNothing() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let waiting = makeOperation(reporter, gesture: .drop)

        reporter.queued(waiting)

        #expect(reporter.report == .idle)
    }

    @Test("a queued operation stops being counted once it retires")
    func aQueuedOperationStopsBeingCountedWhenItRetires() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let running = makeOperation(reporter, gesture: .drop)
        let waiting = makeOperation(reporter, gesture: .drop)

        reporter.publish(from: running, .running(snapshot(bytes: 1, gesture: .drop), since: Date()))
        reporter.queued(waiting)
        reporter.retire(waiting)

        #expect(runningSnapshot(reporter)?.pendingBehind == 0)
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

    @Test("a surface hears once per distinct value")
    func notifiesOncePerDistinctValue() {
        let clock = GatedEngineClock()
        let reporter = makeReporter(clock: clock)
        let operation = makeOperation(reporter)
        var reports: [ClipboardTransferReport] = []
        reporter.onReportChanged = { reports.append($0) }

        let since = Date()
        reporter.publish(from: operation, .running(snapshot(bytes: 5), since: since))
        reporter.publish(from: operation, .running(snapshot(bytes: 5), since: since))
        reporter.publish(from: operation, .running(snapshot(bytes: 6), since: since))
        reporter.retire(operation)

        #expect(reports.count == 3)
        #expect(reports.last == .idle)
    }
}
