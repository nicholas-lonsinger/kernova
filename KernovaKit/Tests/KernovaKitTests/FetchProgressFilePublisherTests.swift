import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Unit tests for `FetchProgressFilePublisher` (#634) — the published
/// `NSProgress` that drives Finder's copy dialog during a relay pull.
///
/// Locks the lifecycle: lazy publish on the first chunk with a non-zero total
/// (kind/fileOperationKind/fileURL/byte denomination), advancement to the
/// total, terminal teardown via `finish()` (with late updates a no-op), and the
/// degraded paths (nil resolution latches; a zero total never publishes).
///
/// All `Progress` state is main-queue-confined, and `record`/`finish` enqueue
/// their work on the main queue synchronously before returning — so an
/// `await MainActor.run` read enqueued afterwards is FIFO-ordered behind every
/// pending apply, making it an event-driven barrier, not a timing wait.
@Suite("FetchProgressFilePublisher")
struct FetchProgressFilePublisherTests {
    private let total: UInt64 = 1_000_000
    private let url = URL(fileURLWithPath: "/tmp/kernova-fp-test/placeholder.bin")

    private static func makeLogger() -> KernovaLogger {
        KernovaLogger(subsystem: "app.kernova.test", category: "FetchProgressFilePublisher")
    }

    @Test("the first recorded chunk publishes a byte-denominated .file/.downloading progress")
    func firstChunkPublishes() async {
        let resolveCount = Box(0)
        let publisher = FetchProgressFilePublisher(
            resolveFileURL: { [url] in
                resolveCount.value += 1
                return url
            }, logger: Self.makeLogger())

        publisher.record(bytesTransferred: 65_536, totalBytes: total)

        let progress = await MainActor.run { publisher.progressForTesting }
        #expect(progress != nil)
        #expect(progress?.kind == .file)
        #expect(progress?.fileOperationKind == .downloading)
        #expect(progress?.totalUnitCount == Int64(total))
        #expect(progress?.completedUnitCount == 65_536)
        #expect(progress?.userInfo[.fileURLKey] as? URL == url)
        // Cancellation rides the fetch path (cancelFetch → failure reply), so
        // the published proxy must not advertise its own cancel/pause.
        #expect(progress?.isCancellable == false)
        #expect(progress?.isPausable == false)
        #expect(resolveCount.value == 1)
        publisher.finish()
    }

    @Test("later chunks advance the same progress; the final chunk reaches the total")
    func advancesToTotal() async {
        let publisher = FetchProgressFilePublisher(
            resolveFileURL: { [url] in url }, logger: Self.makeLogger())

        publisher.record(bytesTransferred: 65_536, totalBytes: total)
        let first = await MainActor.run { publisher.progressForTesting }
        // The final chunk always clears the throttle, however close the calls.
        publisher.record(bytesTransferred: total, totalBytes: total)

        let last = await MainActor.run { publisher.progressForTesting }
        #expect(last === first)
        #expect(last?.completedUnitCount == Int64(total))
        #expect(last?.totalUnitCount == Int64(total))
        publisher.finish()
    }

    @Test("finish unpublishes and clears; a late update after finish is a no-op")
    func finishTearsDown() async {
        let publisher = FetchProgressFilePublisher(
            resolveFileURL: { [url] in url }, logger: Self.makeLogger())

        publisher.record(bytesTransferred: 65_536, totalBytes: total)
        publisher.finish()

        var progress = await MainActor.run { publisher.progressForTesting }
        #expect(progress == nil)

        // A throttled update landing after the terminal must not re-publish.
        publisher.record(bytesTransferred: total, totalBytes: total)
        progress = await MainActor.run { publisher.progressForTesting }
        #expect(progress == nil)
    }

    @Test("a nil resolution latches — nothing publishes and the resolver is not retried per chunk")
    func nilResolutionLatches() async {
        let resolveCount = Box(0)
        let publisher = FetchProgressFilePublisher(
            resolveFileURL: {
                resolveCount.value += 1
                return nil
            }, logger: Self.makeLogger())

        publisher.record(bytesTransferred: 65_536, totalBytes: total)
        publisher.record(bytesTransferred: total, totalBytes: total)

        let progress = await MainActor.run { publisher.progressForTesting }
        #expect(progress == nil)
        #expect(resolveCount.value == 1)
    }

    @Test("a zero-total update never publishes (nothing determinate to render)")
    func zeroTotalDoesNotPublish() async {
        let resolveCount = Box(0)
        let publisher = FetchProgressFilePublisher(
            resolveFileURL: { [url] in
                resolveCount.value += 1
                return url
            }, logger: Self.makeLogger())

        publisher.record(bytesTransferred: 65_536, totalBytes: 0)

        let progress = await MainActor.run { publisher.progressForTesting }
        #expect(progress == nil)
        #expect(resolveCount.value == 0)
    }
}
