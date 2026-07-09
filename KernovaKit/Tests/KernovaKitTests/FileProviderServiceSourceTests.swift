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
    /// Builds a source with no code-signing pins, and a fresh, UUID-suffixed
    /// service name / reconnect notification name per call, so a source can be
    /// constructed without touching production identifiers and parallel tests
    /// can never cross-talk (Darwin notification names are a flat,
    /// process-global namespace).
    ///
    /// The source stands up an anonymous listener in `init` (harmless in a test
    /// process) but never accepts a connection unless the test does so itself,
    /// keeping every pull pending until then.
    private func makeSource(
        connectTimeout: TimeInterval = 30, fetchReplyTimeout: TimeInterval = 120
    ) -> FileProviderServiceSource {
        let unique = UUID().uuidString
        let config = FileProviderConfig(
            appGroupIdentifier: "8MT4P4GZL2.app.kernova.test",
            serviceName: NSFileProviderServiceName("app.kernova.clipboard.test.relay.\(unique)"),
            reconnectNotificationName: "app.kernova.clipboard.test.reconnect.\(unique)",
            domainIdentifier: "kernova-clipboard-test",
            domainDisplayName: "Kernova Clipboard (Test)",
            containerDirectoryName: "FileProviderTest",
            loggerSubsystem: "app.kernova.test",
            extensionLoggerSubsystem: "app.kernova.test.fileprovider",
            ownerCodeSigningRequirement: nil,
            extensionCodeSigningRequirement: nil)
        return FileProviderServiceSource(
            config: config,
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
        let source = makeSource()

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
        // implementation, so a throwaway value stands in for the
        // framework-provided one; `newConnection` only needs to be a valid
        // connection object, since the drain itself never depends on a live peer
        // answering it.
        let throwawayConnection = NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)
        _ = source.listener(NSXPCListener.anonymous(), shouldAcceptNewConnection: throwawayConnection)

        #expect(source.pendingPullCountForTesting == 0)
        throwawayConnection.invalidate()
    }
}
