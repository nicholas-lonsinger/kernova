import Foundation
import Testing

@testable import KernovaKit

/// Holds the dwell work the reporter arms, so a test fires it instead of waiting
/// for it.
private final class DwellScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@MainActor @Sendable () -> Void] = []

    var isArmed: Bool { lock.withLock { !pending.isEmpty } }

    func schedule(after: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { pending.append(work) }
    }

    @MainActor
    func fire() {
        let armed = lock.withLock { () -> [@MainActor @Sendable () -> Void] in
            let armed = pending
            pending.removeAll()
            return armed
        }
        armed.forEach { $0() }
    }
}

/// One-shot flag a `@Sendable` cancel closure can set from any thread.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

@Suite("ClipboardTransferReporter")
@MainActor
struct ClipboardTransferReporterTests {
    /// A reporter whose dwell only fires when the test says so.
    private func makeReporter(scheduler: DwellScheduler) -> ClipboardTransferReporter {
        ClipboardTransferReporter(
            dwell: 2, schedule: { after, work in scheduler.schedule(after: after, work) })
    }

    private func makeOperation(
        _ reporter: ClipboardTransferReporter,
        gesture: ClipboardTransferGesture = .paste,
        onCancelRequested: (@Sendable () -> Void)? = nil
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: gesture, direction: .inbound, peerName: "macOS TEST",
            // Nothing is driven through the operation itself here; these seams
            // keep it from touching a real clock or the main queue.
            revealDelay: 0, idleGap: 0, now: { 0 }, schedule: { _, _ in },
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
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
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
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
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
    func completedReportsDwellThenClear() {
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
        let operation = makeOperation(reporter)
        let completed = ClipboardTransferFinish(
            gesture: .paste, outcome: .completed(final: snapshot(bytes: 100)),
            peerName: "macOS TEST")

        reporter.publish(from: operation, .finished(completed))
        #expect(reporter.report == .finished(completed))
        #expect(scheduler.isArmed)

        scheduler.fire()
        #expect(reporter.report == .idle)
    }

    @Test("a refusal never dwells — it stands until something displaces or clears it")
    func failedReportsStand() {
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)

        reporter.finish(finish(.timedOut))
        #expect(!scheduler.isArmed)
        guard case .finished = reporter.report else {
            Issue.record("expected the refusal to stand")
            return
        }

        reporter.clearFinished()
        #expect(reporter.report == .idle)
    }

    @Test("a dwell armed for one report is defused by the next")
    func aNewReportDefusesTheDwell() {
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
        let operation = makeOperation(reporter)
        let completed = ClipboardTransferFinish(
            gesture: .paste, outcome: .completed(final: snapshot(bytes: 100)),
            peerName: "macOS TEST")

        reporter.publish(from: operation, .finished(completed))
        let next = makeOperation(reporter)
        reporter.publish(from: next, .running(snapshot(bytes: 5), since: Date()))
        scheduler.fire()

        guard case .running = reporter.report else {
            Issue.record("the stale dwell must not clear the newer readout")
            return
        }
    }

    // MARK: - A refusal raised alongside another operation

    @Test("a refusal raised during another operation survives that operation's completion")
    func refusalOutlivesAConcurrentOperation() {
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
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
        scheduler.fire()
        #expect(reporter.report == .finished(refusal))
    }

    @Test("a retry that succeeds clears a failure that stood before it began")
    func aLaterSuccessClearsAnOlderFailure() {
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
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
        scheduler.fire()
        #expect(reporter.report == .idle)
    }

    // MARK: - Absorbing repeats

    @Test("the repeated fires of one refused paste raise one report")
    func absorbsARepeatedRefusal() {
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
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
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
        let operation = makeOperation(reporter)

        reporter.finish(finish(.incompleteFileSet, at: Date(timeIntervalSince1970: 1)))
        reporter.publish(from: operation, .running(snapshot(bytes: 5), since: Date()))
        reporter.retire(operation)
        let later = finish(.incompleteFileSet, at: Date(timeIntervalSince1970: 2))
        reporter.finish(later)

        #expect(reporter.report == .finished(later))
    }

    // MARK: - Surface entry points

    @Test("clearing a finished report leaves a running one alone")
    func clearFinishedLeavesRunningAlone() {
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
        let operation = makeOperation(reporter)

        reporter.publish(from: operation, .running(snapshot(bytes: 5), since: Date()))
        reporter.clearFinished()
        guard case .running = reporter.report else {
            Issue.record("expected the running readout to survive")
            return
        }
    }

    @Test("a cancel reaches the newest running operation, not an older one")
    func cancelReachesTheNewestOperation() {
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
        let olderStopped = AtomicFlag()
        let newerStopped = AtomicFlag()
        let older = makeOperation(reporter, onCancelRequested: { olderStopped.set() })
        let newer = makeOperation(reporter, onCancelRequested: { newerStopped.set() })

        reporter.publish(from: older, .running(snapshot(bytes: 1), since: Date()))
        reporter.publish(from: newer, .running(snapshot(bytes: 2), since: Date()))
        reporter.cancelRunning()

        #expect(newerStopped.value)
        #expect(!olderStopped.value)
    }

    @Test("a cancel skips a newer operation that cannot be stopped")
    func cancelSkipsANonCancellableNewestOperation() {
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
        let stopped = AtomicFlag()
        let cancellable = makeOperation(reporter, onCancelRequested: { stopped.set() })
        // A paste fire: the pasteboard drives it one item at a time, so there is
        // nothing a Cancel could usefully stop.
        let pasteFire = makeOperation(reporter)

        reporter.publish(from: cancellable, .running(snapshot(bytes: 1), since: Date()))
        reporter.publish(from: pasteFire, .running(snapshot(bytes: 2), since: Date()))
        reporter.cancelRunning()

        #expect(stopped.value)
    }

    @Test("a surface hears once per distinct value")
    func notifiesOncePerDistinctValue() {
        let scheduler = DwellScheduler()
        let reporter = makeReporter(scheduler: scheduler)
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
