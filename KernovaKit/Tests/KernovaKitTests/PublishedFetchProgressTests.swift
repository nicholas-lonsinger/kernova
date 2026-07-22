import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `PublishedFetchProgress` (#634) — the cross-process
/// `NSProgress` that makes Finder's copy dialog render a determinate bar for a
/// File Provider paste.
///
/// The `ProgressPublication` seam is injected throughout, so nothing here ever
/// calls the real `Progress.publish()` and registers a system-wide progress from
/// a test bundle. The reveal delay is injected too — `0` to drive the revealed
/// path (the *second* `record` is by definition at least zero seconds after the
/// first) and a never-fire value to drive the suppressed path — so no case
/// sleeps or depends on how fast the runner is.
@Suite("PublishedFetchProgress")
struct PublishedFetchProgressTests {
    private let fileURL = URL(
        fileURLWithPath: "/Users/test/Library/CloudStorage/Kernova-clipboard/report.pdf")
    private let logger = KernovaLogger(subsystem: "app.kernova.test", category: "PublishedProgress")

    /// A reveal delay no test can reach, driving the "never published" path.
    ///
    /// RATIONALE: this is the behavior under test (per docs/TESTING.md an
    /// injected production timeout must be either that or sized past a scheduler
    /// stall) — a bar that must not appear. An hour makes "did not elapse"
    /// unambiguous even on a fully starved runner.
    private let neverReveals: TimeInterval = 3600

    /// Records what the publisher published/unpublished, standing in for the
    /// system-wide progress registry.
    ///
    /// `@unchecked Sendable`: both closures are invoked only on the main queue
    /// (the publisher's contract), which is what makes the unlocked
    /// read-modify-writes below safe.
    private final class PublicationRecorder: @unchecked Sendable {
        private(set) var published: [Progress] = []
        private(set) var unpublishCount = 0

        var publication: ProgressPublication {
            ProgressPublication(
                publish: { [self] progress in published.append(progress) },
                unpublish: { [self] _ in unpublishCount += 1 })
        }
    }

    /// Suspends until every main-queue block enqueued so far has run.
    ///
    /// `record` and `finish` each enqueue their main-queue hop synchronously
    /// before returning, so a block enqueued after them runs only once they have
    /// — FIFO ordering, not a poll and not a timing assumption. This is how the
    /// negative assertions ("nothing was published") are made without waiting on
    /// an event that by definition never arrives.
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("nothing is published before the reveal delay elapses")
    func nothingPublishedBeforeReveal() async {
        let recorder = PublicationRecorder()
        let progress = PublishedFetchProgress(
            fileURL: fileURL, logger: logger, onCancel: nil, publication: recorder.publication,
            revealDelay: neverReveals)

        progress.record(bytesTransferred: 1_000, totalBytes: 10_000)
        progress.record(bytesTransferred: 5_000, totalBytes: 10_000)
        progress.record(bytesTransferred: 10_000, totalBytes: 10_000)
        await drainMainQueue()

        #expect(recorder.published.isEmpty)
    }

    @Test("exactly one publish once the reveal delay has elapsed")
    func publishesExactlyOnceAfterReveal() async {
        let recorder = PublicationRecorder()
        let progress = PublishedFetchProgress(
            fileURL: fileURL, logger: logger, onCancel: nil, publication: recorder.publication,
            revealDelay: 0)

        // The first record only starts the reveal clock — it can never publish.
        progress.record(bytesTransferred: 1_000, totalBytes: 10_000)
        await drainMainQueue()
        #expect(recorder.published.isEmpty)

        progress.record(bytesTransferred: 2_000, totalBytes: 10_000)
        progress.record(bytesTransferred: 10_000, totalBytes: 10_000)
        await drainMainQueue()

        // Later updates advance the same progress rather than publishing another.
        #expect(recorder.published.count == 1)
    }

    @Test("the published progress carries the file kind, downloading operation, URL and byte total")
    func publishedProgressCarriesFinderMetadata() async throws {
        let recorder = PublicationRecorder()
        let progress = PublishedFetchProgress(
            fileURL: fileURL, logger: logger, onCancel: {}, publication: recorder.publication,
            revealDelay: 0)

        progress.record(bytesTransferred: 1_000, totalBytes: 10_000)
        progress.record(bytesTransferred: 2_000, totalBytes: 10_000)
        await drainMainQueue()

        let published = try #require(recorder.published.first)
        #expect(published.kind == .file)
        #expect(published.fileOperationKind == .downloading)
        #expect(published.userInfo[.fileURLKey] as? URL == fileURL)
        #expect(published.totalUnitCount == 10_000)
        #expect(published.completedUnitCount == 2_000)
        #expect(published.isIndeterminate == false)
        // A subscriber's cancel propagates back to the publisher, so the pull
        // must be abortable through it.
        #expect(published.isCancellable == true)
    }

    @Test("a progress with no cancel handler is not cancellable")
    func noCancelHandlerMeansNotCancellable() async {
        let recorder = PublicationRecorder()
        let progress = PublishedFetchProgress(
            fileURL: fileURL, logger: logger, onCancel: nil, publication: recorder.publication,
            revealDelay: 0)

        progress.record(bytesTransferred: 1_000, totalBytes: 10_000)
        progress.record(bytesTransferred: 2_000, totalBytes: 10_000)
        await drainMainQueue()

        #expect(recorder.published.first?.isCancellable == false)
    }

    @Test("completedUnitCount advances and clamps at the total")
    func completedUnitCountAdvancesAndClamps() async {
        let recorder = PublicationRecorder()
        let progress = PublishedFetchProgress(
            fileURL: fileURL, logger: logger, onCancel: nil, publication: recorder.publication,
            revealDelay: 0)

        progress.record(bytesTransferred: 1_000, totalBytes: 10_000)
        progress.record(bytesTransferred: 2_000, totalBytes: 10_000)
        await drainMainQueue()
        #expect(recorder.published.first?.completedUnitCount == 2_000)

        // A 30% step clears the coalescer's 1% quantum.
        progress.record(bytesTransferred: 5_000, totalBytes: 10_000)
        await drainMainQueue()
        #expect(recorder.published.first?.completedUnitCount == 5_000)

        // The receiver reports *arrived* bytes, which can overshoot a stale
        // total; the bar must sit at 100%, never past it.
        progress.record(bytesTransferred: 12_000, totalBytes: 10_000)
        await drainMainQueue()
        #expect(recorder.published.first?.completedUnitCount == 10_000)
        #expect(recorder.published.count == 1)
    }

    @Test("finish() unpublishes exactly once and a second finish() is a no-op")
    func finishUnpublishesOnce() async {
        let recorder = PublicationRecorder()
        let progress = PublishedFetchProgress(
            fileURL: fileURL, logger: logger, onCancel: nil, publication: recorder.publication,
            revealDelay: 0)

        progress.record(bytesTransferred: 1_000, totalBytes: 10_000)
        progress.record(bytesTransferred: 2_000, totalBytes: 10_000)
        await drainMainQueue()
        #expect(recorder.published.count == 1)

        progress.finish()
        progress.finish()
        await drainMainQueue()

        #expect(recorder.unpublishCount == 1)
    }

    @Test("finish() before anything was published is a no-op")
    func finishBeforePublishIsHarmless() async {
        let recorder = PublicationRecorder()
        let progress = PublishedFetchProgress(
            fileURL: fileURL, logger: logger, onCancel: nil, publication: recorder.publication,
            revealDelay: neverReveals)

        progress.record(bytesTransferred: 1_000, totalBytes: 10_000)
        progress.finish()
        await drainMainQueue()

        #expect(recorder.published.isEmpty)
        #expect(recorder.unpublishCount == 0)
    }

    @Test("a record that lands after finish() never publishes")
    func recordAfterFinishNeverPublishes() async {
        let recorder = PublicationRecorder()
        let progress = PublishedFetchProgress(
            fileURL: fileURL, logger: logger, onCancel: nil, publication: recorder.publication,
            revealDelay: 0)

        // Past the reveal gate but not yet published, so the finish latch — not
        // an already-published progress — is what has to stop the late update.
        progress.record(bytesTransferred: 1_000, totalBytes: 10_000)
        progress.finish()
        progress.record(bytesTransferred: 2_000, totalBytes: 10_000)
        await drainMainQueue()

        #expect(recorder.published.isEmpty)
        #expect(recorder.unpublishCount == 0)
    }

    @Test("a pull with no announced total never publishes")
    func zeroTotalNeverPublishes() async {
        let recorder = PublicationRecorder()
        let progress = PublishedFetchProgress(
            fileURL: fileURL, logger: logger, onCancel: nil, publication: recorder.publication,
            revealDelay: 0)

        progress.record(bytesTransferred: 1_000, totalBytes: 0)
        progress.record(bytesTransferred: 2_000, totalBytes: 0)
        progress.record(bytesTransferred: 3_000, totalBytes: 0)
        await drainMainQueue()

        #expect(recorder.published.isEmpty)
    }

    @Test("the production reveal delay matches the in-app transfer bar's")
    func productionRevealDelayMatchesInAppBar() {
        // The two indicators appear together; `VsockClipboardService`'s own
        // constant lives in the app target, which KernovaKit must not import.
        #expect(PublishedFetchProgress.defaultRevealDelay == 0.3)
    }
}
