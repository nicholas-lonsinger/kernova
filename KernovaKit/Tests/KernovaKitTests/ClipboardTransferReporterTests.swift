import Foundation
import KernovaSynchronization
import KernovaTestSupport
import Testing

@testable import KernovaTransferProgress

@Suite("ClipboardTransferReporter", .caseScoped)
@MainActor
struct ClipboardTransferReporterTests {
    /// A reporter whose dwell passes only when the test releases it from `clock`.
    private func makeReporter(clock: GatedEngineClock) -> ClipboardTransferReporter {
        ClipboardTransferReporter(clock: clock)
    }

    private func makeOperation(
        _ reporter: ClipboardTransferReporter,
        gesture: ClipboardTransferGesture = .paste,
        onCancelRequested: (@MainActor @Sendable () -> Void)? = nil
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

    // MARK: - The log

    @Test("the public log line of a drag out naming the entry the VM couldn't read holds none of its names")
    func unreadEntryStaysOutOfTheLog() throws {
        let names = ["Tax Returns", "Q3", "return.pdf"]
        var account = DragOutAccount(items: 3)
        account.landed = 2
        account.unreadable = .one(entry: ItemEntry(names))
        let finish = ClipboardTransferFinish(
            gesture: .dragOut, outcome: .failed(.dragOutShortfall(account)), peerName: "macOS TEST")

        let line = try #require(finish.logLine)
        for name in names { #expect(!line.contains(name), "\(line)") }
    }
}
