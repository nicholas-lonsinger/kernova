import Foundation
import KernovaKit

/// A `ClipboardTransferReporter` plus every report it has published, for a test
/// asserting on what a surface would render.
///
/// The dwell runs on a `TestEngineClock`, so it passes as soon as it is armed
/// rather than being disabled: a completed operation's readout retires on its
/// own, and a wait on the readout clearing is event-driven. A refusal never
/// dwells, so it stands for the whole test.
@MainActor
public final class ClipboardTransferReports {
    /// The reporter under test, its dwell passing as soon as it is armed.
    public let reporter = ClipboardTransferReporter(clock: TestEngineClock())

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

    /// Suspends until `predicate` holds, re-checked on each report.
    public func wait(
        timeout: TimeInterval = testWaitBackstop,
        until predicate: @MainActor () -> Bool
    ) async throws {
        try await changed.wait(timeout: timeout, until: predicate)
    }

    /// Every distinct refusal that stood, in order.
    ///
    /// A surface that interrupts presents one notice per refusal *date*, so the
    /// count is how many times the reports announced a failure to the user.
    public var refusals: [ClipboardTransferFinish] {
        var distinct: [ClipboardTransferFinish] = []
        for report in reports {
            guard case .finished(let finish) = report, finish.failure != nil,
                !distinct.contains(where: { $0.date == finish.date })
            else { continue }
            distinct.append(finish)
        }
        return distinct
    }

    /// Suspends until a refusal stands.
    public func waitForFailure() async throws {
        try await wait { self.failure != nil }
    }
}
