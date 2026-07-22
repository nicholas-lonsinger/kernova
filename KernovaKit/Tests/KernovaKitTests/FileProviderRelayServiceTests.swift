import FileProvider
import Foundation
import Testing
import KernovaTestSupport

@testable import KernovaKit

/// Unit tests for `FileProviderRelayService` — the relay the owner
/// exports over the `NSFileProviderServicing` connection (#460).
///
/// The extension calls `fetchFile` back on it at `fetchContents`; this exercises
/// the reply contract (staged path on success, mapped `NSFileProviderError` on
/// failure) without standing up a live anonymous-XPC connection.
///
/// Both `fetchFile` and `cancelFetch` dispatch their actual work onto the
/// relay's own `pullQueue` and return immediately (#464 — so neither is ever
/// stuck behind the other on a shared serial queue, mirroring
/// `NSXPCConnection`'s real per-connection delivery queue). Every test below
/// waits for the provider-side effect via `AsyncGate` rather than asserting
/// immediately after the call returns.
@Suite("FileProviderRelayService")
struct FileProviderRelayServiceTests {
    /// Records the `(generation, repIndex)` it was asked for and returns a fixed
    /// result, so forwarding and result mapping can be asserted; `progressEvents`
    /// are fired through `onProgress` before returning, standing in for the
    /// receiver's per-chunk callbacks.
    private final class MockPullProvider: FileProviderPullProvider, @unchecked Sendable {
        private let lastFetchCallBox = Box<(UInt64, Int)?>(nil)
        private let lastCancelCallBox = Box<(UInt64, Int)?>(nil)
        var lastFetchCall: (UInt64, Int)? { lastFetchCallBox.value }
        var lastCancelCall: (UInt64, Int)? { lastCancelCallBox.value }
        let cancelled = AsyncGate()
        let result: Result<String, FileProviderPullError>
        let progressEvents: [(UInt64, UInt64)]

        init(
            result: Result<String, FileProviderPullError>,
            progressEvents: [(UInt64, UInt64)] = []
        ) {
            self.result = result
            self.progressEvents = progressEvents
        }

        func fetchStagedFile(
            generation: UInt64, repIndex: Int,
            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
        ) -> Result<String, FileProviderPullError> {
            lastFetchCallBox.value = (generation, repIndex)
            for (bytes, total) in progressEvents { onProgress(bytes, total) }
            return result
        }

        func cancelStagedPull(generation: UInt64, repIndex: Int) {
            lastCancelCallBox.value = (generation, repIndex)
            cancelled.notify()
        }

        func fetchStagedChild(
            generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
        ) -> Result<String, FileProviderPullError> {
            lastFetchCallBox.value = (generation, repIndex)
            for (bytes, total) in progressEvents { onProgress(bytes, total) }
            return result
        }

        func cancelStagedChildPull(generation: UInt64, repIndex: Int, childSeq: UInt32) {
            lastCancelCallBox.value = (generation, repIndex)
            cancelled.notify()
        }
    }

    /// Blocks inside `fetchStagedFile` until the test releases it, and records
    /// `cancelStagedPull` calls.
    ///
    /// Used to prove the #464 regression this fix closes: a `cancelFetch` call
    /// made while a `fetchFile` pull for the same connection is still in flight
    /// must still reach `cancelStagedPull`. That would be impossible if
    /// `fetchFile` still blocked its caller for the whole pull (the removed
    /// "blocks the XPC queue... safe" behavior) — `NSXPCConnection` delivers
    /// every incoming call, `cancelFetch` included, on one private serial queue
    /// per connection, so a still-blocking `fetchFile` would starve it.
    ///
    /// `DispatchSemaphore`, not `AsyncGate`, guards the block itself:
    /// `fetchStagedFile` runs synchronously inside `pullQueue`'s plain
    /// `DispatchQueue.async` closure (not a `Task`), mirroring the real blocking
    /// vsock pull it stands in for — an `await` isn't available there. The
    /// `entered` `AsyncGate` is only how the test observes that the block has
    /// actually started.
    private final class BlockingPullProvider: FileProviderPullProvider, @unchecked Sendable {
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private let hasEnteredBox = Box(false)
        private let lastCancelCallBox = Box<(UInt64, Int)?>(nil)
        let entered = AsyncGate()
        let cancelled = AsyncGate()
        var hasEntered: Bool { hasEnteredBox.value }
        var lastCancelCall: (UInt64, Int)? { lastCancelCallBox.value }

        func fetchStagedFile(
            generation: UInt64, repIndex: Int,
            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
        ) -> Result<String, FileProviderPullError> {
            hasEnteredBox.value = true
            entered.notify()
            releaseSemaphore.wait()
            return .success("/staged/file")
        }

        func cancelStagedPull(generation: UInt64, repIndex: Int) {
            lastCancelCallBox.value = (generation, repIndex)
            cancelled.notify()
        }

        func fetchStagedChild(
            generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
        ) -> Result<String, FileProviderPullError> {
            hasEnteredBox.value = true
            entered.notify()
            releaseSemaphore.wait()
            return .success("/staged/child")
        }

        func cancelStagedChildPull(generation: UInt64, repIndex: Int, childSeq: UInt32) {
            lastCancelCallBox.value = (generation, repIndex)
            cancelled.notify()
        }

        /// Lets the parked `fetchStagedFile` call return.
        func release() {
            releaseSemaphore.signal()
        }
    }

    @Test("fetchFile forwards (generation, repIndex) and replies with the staged path on success")
    func successRepliesWithStagedPath() async throws {
        let provider = MockPullProvider(result: .success("/staged/file"))
        let service = FileProviderRelayService(
            pullProvider: provider, loggerSubsystem: "app.kernova.test")
        let path = Box<String?>(nil)
        let error = Box<NSError?>(nil)
        let gate = AsyncGate()

        service.fetchFile(generation: 7, repIndex: 3) { stagedPath, nsError in
            path.value = stagedPath
            error.value = nsError
            gate.notify()
        }

        try await gate.wait { path.value != nil || error.value != nil }
        #expect(provider.lastFetchCall?.0 == 7)
        #expect(provider.lastFetchCall?.1 == 3)
        #expect(path.value == "/staged/file")
        #expect(error.value == nil)
    }

    @Test("a noCurrentOffer pull failure maps to NSFileProviderError.noSuchItem")
    func noCurrentOfferMapsToNoSuchItem() async throws {
        let service = FileProviderRelayService(
            pullProvider: MockPullProvider(result: .failure(.noCurrentOffer)),
            loggerSubsystem: "app.kernova.test")
        let path = Box<String?>("unset")
        let error = Box<NSError?>(nil)
        let gate = AsyncGate()

        service.fetchFile(generation: 1, repIndex: 0) { stagedPath, nsError in
            path.value = stagedPath
            error.value = nsError
            gate.notify()
        }

        try await gate.wait { error.value != nil }
        #expect(path.value == nil)
        #expect(error.value?.domain == NSFileProviderErrorDomain)
        #expect(error.value?.code == NSFileProviderError.noSuchItem.rawValue)
    }

    @Test("a pullFailed failure maps to NSFileProviderError.serverUnreachable")
    func pullFailedMapsToServerUnreachable() async throws {
        let service = FileProviderRelayService(
            pullProvider: MockPullProvider(result: .failure(.pullFailed)),
            loggerSubsystem: "app.kernova.test")
        let error = Box<NSError?>(nil)
        let gate = AsyncGate()

        service.fetchFile(generation: 1, repIndex: 0) { _, nsError in
            error.value = nsError
            gate.notify()
        }

        try await gate.wait { error.value != nil }
        #expect(error.value?.domain == NSFileProviderErrorDomain)
        #expect(error.value?.code == NSFileProviderError.serverUnreachable.rawValue)
    }

    @Test("cancelFetch forwards (generation, repIndex) to the pull provider")
    func cancelFetchForwardsToProvider() async throws {
        let provider = MockPullProvider(result: .success("/staged/file"))
        let service = FileProviderRelayService(
            pullProvider: provider, loggerSubsystem: "app.kernova.test")

        // `cancelFetch` dispatches onto `pullQueue` and returns immediately
        // (same reasoning as `fetchFile` — see the relay's own doc), so this
        // must wait for the provider-side effect rather than asserting right
        // after the call returns.
        service.cancelFetch(generation: 4, repIndex: 1)

        try await provider.cancelled.wait { provider.lastCancelCall != nil }
        #expect(provider.lastCancelCall?.0 == 4)
        #expect(provider.lastCancelCall?.1 == 1)
    }

    @Test(
        "cancelFetch reaches the provider while fetchFile's pull for the same fetch is still in flight"
    )
    func cancelFetchDeliveredWhileFetchInFlight() async throws {
        let provider = BlockingPullProvider()
        let service = FileProviderRelayService(
            pullProvider: provider, loggerSubsystem: "app.kernova.test")
        let reply = Box<(String?, NSError?)?>(nil)
        let replyGate = AsyncGate()

        // `fetchFile` must return control to its caller immediately — it no
        // longer blocks the caller for the whole pull (#464) — so this call
        // completes even though `provider.fetchStagedFile` is about to park.
        service.fetchFile(generation: 2, repIndex: 0) { path, error in
            reply.value = (path, error)
            replyGate.notify()
        }

        try await provider.entered.wait { provider.hasEntered }

        // The pull is now genuinely in flight (parked in `fetchStagedFile`).
        // `cancelFetch` must still reach the provider — proving it isn't queued
        // behind the still-running `fetchFile` call (both run concurrently on
        // `pullQueue`, so this doesn't deadlock waiting on the same serial
        // queue the parked pull occupies).
        service.cancelFetch(generation: 2, repIndex: 0)
        try await provider.cancelled.wait { provider.lastCancelCall != nil }
        #expect(provider.lastCancelCall?.0 == 2)
        #expect(provider.lastCancelCall?.1 == 0)

        // Let the parked pull finish and confirm the original fetch still
        // completes normally — the cancel signal doesn't interfere with a reply
        // already in flight (the pull provider's own cancel handling is what
        // decides whether to actually abort; the relay just forwards).
        provider.release()
        try await replyGate.wait { reply.value != nil }
        #expect(reply.value?.0 == "/staged/file")
    }

    @Test(
        "fetchFile keys the file-progress resolver by (generation, repIndex) and finishes the publisher at reply"
    )
    func fetchFileDrivesFileProgressPublisher() async throws {
        let url = URL(fileURLWithPath: "/tmp/kernova-relay-test/file.bin")
        let provider = MockPullProvider(
            result: .success("/staged/file"),
            progressEvents: [(65_536, 1_000_000), (1_000_000, 1_000_000)])
        let service = FileProviderRelayService(
            pullProvider: provider, loggerSubsystem: "app.kernova.test")
        let resolverCalls = Box<[(UInt64, Int, UInt32?)]>([])
        service.visibleFileURLResolver = { generation, repIndex, childSeq in
            resolverCalls.value.append((generation, repIndex, childSeq))
            return url
        }
        let replied = Box(false)
        let gate = AsyncGate()

        service.fetchFile(generation: 7, repIndex: 3) { _, _ in
            replied.value = true
            gate.notify()
        }

        try await gate.wait { replied.value }
        // The reply fired after `finish()` enqueued its main-queue teardown, and
        // this read is enqueued behind it — so a nil progress here proves the
        // publish lifecycle ran to its terminal, not that it never started (the
        // resolver call count proves the publish happened).
        let publisher = try #require(service.lastFilePublisherForTesting)
        let progress = await MainActor.run { publisher.progressForTesting }
        #expect(progress == nil)
        #expect(resolverCalls.value.count == 1)
        #expect(resolverCalls.value.first?.0 == 7)
        #expect(resolverCalls.value.first?.1 == 3)
        #expect(resolverCalls.value.first?.2 == nil)
    }

    @Test("fetchChild keys the file-progress resolver by childSeq")
    func fetchChildDrivesFileProgressPublisherWithChildSeq() async throws {
        let url = URL(fileURLWithPath: "/tmp/kernova-relay-test/folder/sub/file.txt")
        let provider = MockPullProvider(
            result: .success("/staged/child"),
            progressEvents: [(65_536, 500_000), (500_000, 500_000)])
        let service = FileProviderRelayService(
            pullProvider: provider, loggerSubsystem: "app.kernova.test")
        let resolverCalls = Box<[(UInt64, Int, UInt32?)]>([])
        service.visibleFileURLResolver = { generation, repIndex, childSeq in
            resolverCalls.value.append((generation, repIndex, childSeq))
            return url
        }
        let replied = Box(false)
        let gate = AsyncGate()

        service.fetchChild(generation: 2, repIndex: 1, childSeq: 5, relativePath: "sub/file.txt") {
            _, _ in
            replied.value = true
            gate.notify()
        }

        try await gate.wait { replied.value }
        let publisher = try #require(service.lastFilePublisherForTesting)
        let progress = await MainActor.run { publisher.progressForTesting }
        #expect(progress == nil)
        #expect(resolverCalls.value.count == 1)
        #expect(resolverCalls.value.first?.0 == 2)
        #expect(resolverCalls.value.first?.1 == 1)
        #expect(resolverCalls.value.first?.2 == 5)
    }
}
