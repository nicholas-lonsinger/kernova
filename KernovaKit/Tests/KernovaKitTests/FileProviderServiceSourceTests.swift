import FileProvider
import Foundation
import Testing
import os

@testable import KernovaKit

/// Unit tests for `FileProviderServiceSource` (#460) — the extension-side
/// servicing endpoint: cancellation (the handle returned by `fetchStagedFile`,
/// wiring Finder's cancel button via the `fetchContents` `Progress`), the
/// connect-timeout terminal (`failPending`, where a retain-cycle leak once
/// lived), and the accept-time drain (#465).
///
/// Cancellation and the connect-timeout terminal exercise the *pending* pull
/// path, which needs no live owner connection: with nothing accepted,
/// `fetchStagedFile` enqueues the pull and returns, so each completes
/// deterministically without standing up an anonymous-XPC round trip.
@Suite("FileProviderServiceSource")
struct FileProviderServiceSourceTests {
    /// A fake owner relay: never replies to `fetchFile` (so a pull can be
    /// observed "in flight"), and records `cancelFetch` calls.
    ///
    /// Owns its own anonymous listener and is its own `NSXPCListenerDelegate` —
    /// mirroring `FileProviderServicingConnectorTests.LoopbackControlPeer` —
    /// rather than a separate delegate object, since `NSXPCListener.delegate` is
    /// `weak` and a standalone delegate with no other owner would be
    /// deallocated immediately. This is the "owner" side backing the
    /// `NSXPCConnection` the test hands directly to
    /// `source.listener(_:shouldAcceptNewConnection:)` (mirroring
    /// `acceptDrainsPendingPull`'s pattern, but with a real, working peer
    /// instead of an inert placeholder, since this test needs `performPull`'s
    /// `remoteObjectProxy` call to actually reach it).
    private final class RecordingRelay: NSObject, NSXPCListenerDelegate, FileProviderRelay,
        @unchecked Sendable
    {
        private let listener = NSXPCListener.anonymous()
        private let lock = NSLock()
        private var cancelCallStorage: (UInt64, Int)?
        private var fetchFileEnteredStorage = false
        var cancelCall: (UInt64, Int)? { lock.withLock { cancelCallStorage } }
        var fetchFileHasEntered: Bool { lock.withLock { fetchFileEnteredStorage } }
        let fetchFileEntered = AsyncGate()
        let cancelFetchCalled = AsyncGate()

        override init() {
            super.init()
            listener.delegate = self
            listener.resume()
        }

        var endpoint: NSXPCListenerEndpoint { listener.endpoint }

        func listener(
            _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
        ) -> Bool {
            newConnection.exportedInterface = NSXPCInterface(with: FileProviderRelay.self)
            newConnection.exportedObject = self
            newConnection.resume()
            return true
        }

        func fetchFile(
            generation: UInt64, repIndex: Int,
            reply: @escaping @Sendable (String?, NSError?) -> Void
        ) {
            // Deliberately never replies — the test cancels while this "pull" is
            // still in flight, then tears the connection down.
            lock.withLock { fetchFileEnteredStorage = true }
            fetchFileEntered.notify()
        }

        func cancelFetch(generation: UInt64, repIndex: Int) {
            lock.withLock { cancelCallStorage = (generation, repIndex) }
            cancelFetchCalled.notify()
        }

        func invalidate() {
            listener.invalidate()
        }
    }

    /// Builds a source over a fresh `makeTestFileProviderConfig()` (see
    /// `StreamTestSupport.swift`), so a source can be constructed without
    /// touching production identifiers.
    ///
    /// The source stands up an anonymous listener in `init` (harmless in a test
    /// process) but never accepts a connection unless the test does so itself,
    /// keeping every pull pending until then.
    private func makeSource(
        connectTimeout: TimeInterval = 30, fetchReplyTimeout: TimeInterval = 120
    ) -> FileProviderServiceSource {
        FileProviderServiceSource(
            config: makeTestFileProviderConfig(),
            logger: Logger(subsystem: "app.kernova.test", category: "ServiceSourceTest"),
            connectTimeout: connectTimeout, fetchReplyTimeout: fetchReplyTimeout)
    }

    @Test("cancelling a pending pull completes it once with NSUserCancelledError")
    func cancelPendingPullCompletesWithUserCancelled() {
        let source = makeSource()
        let result = Box<Result<String, NSError>?>(nil)

        // No accepted connection → the pull enqueues and waits; the completion has
        // not run yet.
        let cancellation = source.fetchStagedFile(generation: 5, repIndex: 2) { outcome in
            result.value = outcome
        }
        #expect(result.value == nil)

        cancellation.cancel()

        guard case .failure(let error)? = result.value else {
            Issue.record("expected a failure result after cancel, got \(String(describing: result.value))")
            return
        }
        #expect(error.domain == NSCocoaErrorDomain)
        #expect(error.code == NSUserCancelledError)
    }

    @Test("cancel is idempotent — the completion fires exactly once across repeated cancels")
    func cancelIsIdempotent() {
        let source = makeSource()
        let callCount = Box(0)

        let cancellation = source.fetchStagedFile(generation: 1, repIndex: 0) { _ in
            callCount.value += 1
        }
        cancellation.cancel()
        cancellation.cancel()
        cancellation.cancel()

        #expect(callCount.value == 1)
    }

    @Test("the connect-timeout terminal fails a pending pull with serverUnreachable")
    func connectTimeoutFailsPendingPullWithServerUnreachable() async throws {
        let source = makeSource(connectTimeout: 0.05)
        let result = Box<Result<String, NSError>?>(nil)
        let gate = AsyncGate()

        // No accepted connection → enqueues, rings the doorbell, and arms the
        // connect-timeout timer under test (the doorbell post itself has no
        // observer here — a harmless no-op, as in the existing cancellation tests).
        _ = source.fetchStagedFile(generation: 9, repIndex: 1) { outcome in
            result.value = outcome
            gate.notify()
        }

        try await gate.wait { result.value != nil }

        guard case .failure(let error)? = result.value else {
            Issue.record(
                "expected a failure result after the connect timeout, got \(String(describing: result.value))"
            )
            return
        }
        #expect(error.domain == NSFileProviderErrorDomain)
        #expect(error.code == NSFileProviderError.serverUnreachable.rawValue)
    }

    @Test("accepting a connection drains a pending pull off the pending queue")
    func acceptDrainsPendingPull() {
        // Small timeouts: this test is fully synchronous (no `await`), so
        // neither timer can race the assertions below — they just let the
        // pull's never-cancelled background timers (see the source's docs)
        // resolve near-instantly instead of lingering for the production
        // 30s/120s defaults.
        let source = makeSource(connectTimeout: 0.05, fetchReplyTimeout: 0.05)

        // No accepted connection → enqueues and waits.
        _ = source.fetchStagedFile(generation: 3, repIndex: 0) { _ in
            // Not asserted on: with no live peer behind `throwawayConnection`
            // below, this eventually fails asynchronously (matching production,
            // which never cancels a pull's timers) — this test only cares that
            // the drain moved the pull off the pending queue, not what happens to
            // it afterward.
        }
        #expect(source.pendingPullCountForTesting == 1)

        // `shouldAcceptNewConnection`'s `listener` parameter is unused by the
        // implementation, so the same listener stands in for both it and the
        // endpoint backing `throwawayConnection` — the drain itself never
        // depends on a live peer answering it.
        let throwawayListener = NSXPCListener.anonymous()
        let throwawayConnection = NSXPCConnection(listenerEndpoint: throwawayListener.endpoint)
        _ = source.listener(throwawayListener, shouldAcceptNewConnection: throwawayConnection)

        #expect(source.pendingPullCountForTesting == 0)
        throwawayConnection.invalidate()
    }

    @Test("cancelling a pull already dispatched to the owner asks the owner to abort it (#464)")
    func cancelDispatchedPullAsksOwnerToAbort() async throws {
        // Short reply timeout: the relay below never replies, so this just
        // bounds how long the (already-cancelled, harmless) background timer
        // lingers rather than sitting at the 120s production default.
        let source = makeSource(fetchReplyTimeout: 2)
        let relay = RecordingRelay()
        defer { relay.invalidate() }

        // A connection whose remote peer is `relay`'s own listener — handed
        // directly to `shouldAcceptNewConnection`, exactly like
        // `acceptDrainsPendingPull`, so the source treats it as its one live
        // owner connection.
        let connection = NSXPCConnection(listenerEndpoint: relay.endpoint)
        defer { connection.invalidate() }
        _ = source.listener(NSXPCListener.anonymous(), shouldAcceptNewConnection: connection)

        let result = Box<Result<String, NSError>?>(nil)
        // A live connection exists, so this dispatches immediately over it
        // (the fast path) rather than enqueueing — `relay.fetchFile` is called
        // synchronously within this call.
        let cancellation = source.fetchStagedFile(generation: 11, repIndex: 2) { outcome in
            result.value = outcome
        }

        try await relay.fetchFileEntered.wait { relay.fetchFileHasEntered }

        cancellation.cancel()

        // The local completion fires immediately with the user-cancelled
        // sentinel — this much also holds for a still-*pending* pull (see
        // `cancelPendingPullCompletesWithUserCancelled` above, where no
        // connection exists at all and the owner-abort branch is simply
        // unreachable). What's new here is the owner round trip below.
        guard case .failure(let error)? = result.value else {
            Issue.record(
                "expected a failure result after cancel, got \(String(describing: result.value))")
            return
        }
        #expect(error.domain == NSCocoaErrorDomain)
        #expect(error.code == NSUserCancelledError)

        // The owner must be told to stop streaming bytes nobody will read (#464).
        try await relay.cancelFetchCalled.wait { relay.cancelCall != nil }
        #expect(relay.cancelCall?.0 == 11)
        #expect(relay.cancelCall?.1 == 2)
    }
}
