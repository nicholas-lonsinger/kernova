import Foundation
import KernovaKit

/// A `ClipboardTransferReporter` plus every report it has published, for a test
/// asserting on what a surface would render.
///
/// The dwell is zeroed rather than disabled: a completed operation's readout
/// retires on the next main-queue turn, so a wait on the readout clearing is
/// event-driven. A refusal never dwells, so it stands for the whole test.
@MainActor
public final class ClipboardTransferReports {
    /// The reporter under test, with the dwell zeroed.
    public let reporter = ClipboardTransferReporter(dwell: 0)

    /// Every distinct report, oldest first.
    public private(set) var reports: [ClipboardTransferReport] = []

    /// Notified on each report, for an event-driven wait.
    public let changed = AsyncGate()

    /// Creates a recorder wired to a fresh reporter.
    public init() {
        reporter.onReportChanged = { [weak self] report in
            self?.reports.append(report)
            self?.changed.notify()
        }
    }

    /// The report a surface would render right now.
    public var latest: ClipboardTransferReport { reporter.report }

    /// The standing finished report, or `nil` when none stands.
    public var finish: ClipboardTransferFinish? {
        guard case .finished(let finish) = latest else { return nil }
        return finish
    }

    /// The standing refusal, or `nil` when the report is not a failure.
    public var failure: ClipboardTransferFailure? { finish?.failure }

    /// The readout a bar would show — live while running, the last one while a
    /// completed or cancelled report stands.
    public var snapshot: ClipboardProgressSnapshot? {
        switch latest {
        case .running(let snapshot, _): return snapshot
        case .finished(let finish): return finish.finalSnapshot
        case .idle: return nil
        }
    }

    /// The live readout only, for a test that must distinguish a running
    /// operation from one that has ended.
    public var runningSnapshot: ClipboardProgressSnapshot? {
        guard case .running(let snapshot, _) = latest else { return nil }
        return snapshot
    }

    /// Suspends until `predicate` holds, re-checked on each report.
    public func wait(
        timeout: TimeInterval = testWaitBackstop,
        until predicate: @MainActor () -> Bool
    ) async throws {
        try await changed.wait(timeout: timeout, until: predicate)
    }

    /// Every finished operation's last readout, in order.
    ///
    /// Read from the recorded history rather than the live report, so an
    /// assertion about a completed operation's bar cannot race the dwell that
    /// retires it.
    public var finalSnapshots: [ClipboardProgressSnapshot] {
        reports.compactMap { report in
            guard case .finished(let finish) = report else { return nil }
            return finish.finalSnapshot
        }
    }

    /// Suspends until a refusal stands.
    public func waitForFailure() async throws {
        try await wait { self.failure != nil }
    }
}
