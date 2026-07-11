import FileProvider
import Foundation
import Testing
import KernovaTestSupport

@testable import KernovaKit

/// Unit tests for `FileProviderServicingConnector` — the owner-side state
/// machine that reaches the extension's `NSFileProviderServicing` endpoint
/// (#460), covering the races its adversarial review found but never tested
/// (#465): connect-slot coalescing, the retry budget, `stopServing` racing an
/// in-flight connect, and the reconnect-doorbell re-probe.
///
/// Drives the connector through its injected `connect` operation (the
/// `getFileProviderServicesForItem` → `getFileProviderConnection` chain is
/// collapsed into one seam — `NSFileProviderService` is an opaque,
/// non-instantiable system type a test can't fabricate) rather than the real
/// system calls. Every test is deterministic. One (the doorbell re-probe
/// re-sending `ownerDidConnect`) stands up a live in-process anonymous-XPC
/// loopback peer; another (`stopServingRacesSuccessfulConnect`) constructs —
/// but never resumes — a throwaway `NSXPCConnection`/`NSXPCListener` pair
/// purely as an inert placeholder value. None of these tests posts a real
/// Darwin notification: `CFNotificationCenter` only delivers on a running main
/// run loop, which this SwiftPM test target does not host (see
/// `DarwinNotificationTests`) — the doorbell is instead triggered directly via
/// the `#if DEBUG` seam.
@Suite("FileProviderServicingConnector")
struct FileProviderServicingConnectorTests {
    /// A placeholder root URL — never touched by a real File Provider API,
    /// since every test replaces the connect operation with a stub.
    private static let testRootURL = URL(fileURLWithPath: "/tmp/kernova-servicing-connector-test-root")

    /// A `FileProviderRelay` that fails the test if ever called — none of these
    /// state-machine tests drive an actual byte pull.
    private final class NeverCalledRelay: NSObject, FileProviderRelay, @unchecked Sendable {
        func fetchFile(
            generation: UInt64, repIndex: Int,
            reply: @escaping @Sendable (String?, NSError?) -> Void
        ) {
            Issue.record("fetchFile should never be called in FileProviderServicingConnector tests")
            reply(nil, NSError(domain: NSCocoaErrorDomain, code: -1))
        }

        func cancelFetch(generation: UInt64, repIndex: Int) {
            Issue.record("cancelFetch should never be called in FileProviderServicingConnector tests")
        }
    }

    /// A `FileProviderServicingConnector.ConnectOperation` test double.
    ///
    /// Records every call (and notifies `gate`); how it responds is fixed at
    /// construction by `Response`:
    /// - `.capture` never completes on its own — it holds the connect slot open
    ///   until the test fires the captured completion via
    ///   `fireCapturedCompletion(with:)` (coalescing / race tests).
    /// - `.immediate` completes synchronously with a fixed connection (or `nil`
    ///   for failure) on every call (retry-budget / doorbell tests).
    private final class ConnectStub: @unchecked Sendable {
        enum Response {
            case capture
            case immediate(NSXPCConnection?)
        }

        private let lock = NSLock()
        private var callCountStorage = 0
        private var captured: ((NSXPCConnection?) -> Void)?
        private let response: Response
        let gate = AsyncGate()

        init(_ response: Response) {
            self.response = response
        }

        var callCount: Int { lock.withLock { callCountStorage } }

        func record(rootURL: URL, completion: @escaping @Sendable (NSXPCConnection?) -> Void) {
            lock.withLock {
                callCountStorage += 1
                if case .capture = response { captured = completion }
            }
            // For `.immediate`, fire the completion (which synchronously drives the
            // connector's `configureAndResume`/`finishFailedConnect`) BEFORE
            // notifying: a waiter gated on the connector's post-completion state
            // (e.g. `!isConnectingForTesting`) must never observe this call's
            // `notify()` while that state is still mid-transition, since nothing
            // notifies again until the *next* call.
            if case .immediate(let connection) = response { completion(connection) }
            gate.notify()
        }

        /// Fires the most recently captured completion — only meaningful for a
        /// `.capture` stub.
        func fireCapturedCompletion(with connection: NSXPCConnection?) {
            let completion: ((NSXPCConnection?) -> Void)? = lock.withLock {
                defer { captured = nil }
                return captured
            }
            completion?(connection)
        }
    }

    /// A minimal in-process peer standing in for the extension's control listener.
    ///
    /// Used only by the doorbell re-probe test: accepts the connector's
    /// connection, exports `FileProviderControl` so `activate()`'s
    /// `ownerDidConnect` handshake lands, and counts each call.
    private final class LoopbackControlPeer: NSObject, NSXPCListenerDelegate, FileProviderControl,
        @unchecked Sendable
    {
        private let listener = NSXPCListener.anonymous()
        private let lock = NSLock()
        private var acceptedConnection: NSXPCConnection?
        private var ownerDidConnectCountStorage = 0
        let gate = AsyncGate()

        override init() {
            super.init()
            listener.delegate = self
            listener.resume()
        }

        var endpoint: NSXPCListenerEndpoint { listener.endpoint }
        var ownerDidConnectCount: Int { lock.withLock { ownerDidConnectCountStorage } }

        func listener(
            _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
        ) -> Bool {
            newConnection.exportedInterface = NSXPCInterface(with: FileProviderControl.self)
            newConnection.exportedObject = self
            newConnection.remoteObjectInterface = NSXPCInterface(with: FileProviderRelay.self)
            lock.withLock { acceptedConnection = newConnection }
            newConnection.resume()
            return true
        }

        func ownerDidConnect(reply: @escaping @Sendable () -> Void) {
            lock.withLock { ownerDidConnectCountStorage += 1 }
            gate.notify()
            reply()
        }

        /// Invalidates the accepted connection (breaking the connection↔peer
        /// retain cycle `exportedObject` holds) and the listener.
        func invalidate() {
            let connection: NSXPCConnection? = lock.withLock {
                defer { acceptedConnection = nil }
                return acceptedConnection
            }
            connection?.invalidate()
            listener.invalidate()
        }
    }

    private func makeConnector(
        stub: ConnectStub, maxConnectAttempts: Int = 15,
        connectRetryDelay: DispatchTimeInterval = .seconds(2), config: FileProviderConfig
    ) -> FileProviderServicingConnector {
        FileProviderServicingConnector(
            config: config,
            connect: { rootURL, completion in stub.record(rootURL: rootURL, completion: completion) },
            maxConnectAttempts: maxConnectAttempts, connectRetryDelay: connectRetryDelay)
    }

    @Test("a second ensureConnected while a connect is in flight coalesces — no second connect call")
    func connectCoalescesWhileInFlight() async throws {
        let stub = ConnectStub(.capture)  // never completes — holds the connect slot
        let connector = makeConnector(stub: stub, config: makeTestFileProviderConfig())
        connector.startServing(NeverCalledRelay())

        connector.ensureConnected(rootURL: Self.testRootURL)
        try await stub.gate.wait { stub.callCount == 1 }
        #expect(connector.isConnectingForTesting)

        // A second trigger while the first is in flight coalesces synchronously
        // (the `connecting` guard) — no further dispatch, so no wait is needed.
        connector.ensureConnected(rootURL: Self.testRootURL)
        #expect(stub.callCount == 1)
    }

    @Test("finishFailedConnect retries up to maxConnectAttempts then gives up")
    func retryBudgetGivesUpAfterMaxAttempts() async throws {
        let stub = ConnectStub(.immediate(nil))
        let connector = makeConnector(
            stub: stub, maxConnectAttempts: 3, connectRetryDelay: .milliseconds(5),
            config: makeTestFileProviderConfig())
        connector.startServing(NeverCalledRelay())

        connector.ensureConnected(rootURL: Self.testRootURL)

        // Gate on the terminal tuple, not `callCount == 3` alone: `connecting`
        // only clears inside the 3rd `finishFailedConnect`, after the 3rd call is
        // already recorded — an intermediate retry also holds `connecting == true`
        // (to keep the slot for the scheduled retry), so this combination is only
        // ever true once the give-up branch has actually run, and it's stable
        // from then on (no further retry is scheduled).
        try await stub.gate.wait {
            stub.callCount == 3 && !connector.isConnectingForTesting
                && connector.connectAttemptsForTesting == 0
        }
        #expect(stub.callCount == 3)
    }

    @Test("stopServing before a captured connect completes successfully refuses to adopt the connection")
    func stopServingRacesSuccessfulConnect() async throws {
        let stub = ConnectStub(.capture)
        let connector = makeConnector(stub: stub, config: makeTestFileProviderConfig())
        connector.startServing(NeverCalledRelay())
        connector.ensureConnected(rootURL: Self.testRootURL)
        try await stub.gate.wait { stub.callCount == 1 }

        connector.stopServing()

        // Any valid connection object works here: `configureAndResume`'s re-check
        // finds `relayService == nil` and never calls `resume()` on it.
        let throwawayConnection = NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)
        stub.fireCapturedCompletion(with: throwawayConnection)

        #expect(!connector.isConnectedForTesting)
        #expect(!connector.isConnectingForTesting)
        throwawayConnection.invalidate()
    }

    @Test("stopServing before a captured connect completes with failure settles with no retry")
    func stopServingRacesFailedConnect() async throws {
        let stub = ConnectStub(.capture)
        let connector = makeConnector(stub: stub, config: makeTestFileProviderConfig())
        connector.startServing(NeverCalledRelay())
        connector.ensureConnected(rootURL: Self.testRootURL)
        try await stub.gate.wait { stub.callCount == 1 }

        connector.stopServing()
        stub.fireCapturedCompletion(with: nil)

        #expect(!connector.isConnectingForTesting)
        #expect(connector.connectAttemptsForTesting == 0)
    }

    @Test(
        "a successfully adopted connection re-probes via ownerDidConnect on the reconnect doorbell, without reconnecting"
    )
    func doorbellReprobesLiveConnection() async throws {
        let peer = LoopbackControlPeer()
        let stub = ConnectStub(.immediate(NSXPCConnection(listenerEndpoint: peer.endpoint)))
        let connector = makeConnector(stub: stub, config: makeTestFileProviderConfig())
        connector.startServing(NeverCalledRelay())
        connector.ensureConnected(rootURL: Self.testRootURL)

        try await peer.gate.wait { peer.ownerDidConnectCount == 1 }
        #expect(connector.isConnectedForTesting)
        #expect(stub.callCount == 1)

        // Not a real Darwin post (see the suite doc) — this directly invokes the
        // handler the doorbell would otherwise trigger.
        connector.triggerReconnectDoorbellForTesting()

        try await peer.gate.wait { peer.ownerDidConnectCount == 2 }
        // Re-probed the existing connection rather than reconnecting.
        #expect(stub.callCount == 1)

        connector.stopServing()
        peer.invalidate()
    }

    @Test("the reconnect doorbell retries a connect attempt when no connection is live")
    func doorbellRetriesConnectWhenDisconnected() async throws {
        // The stub always fails, so this proves the doorbell's disconnected
        // branch triggers a fresh `connectIfNeeded()` call — not that a
        // reconnect actually succeeds (the successful-adopt path is
        // `doorbellReprobesLiveConnection` above).
        let stub = ConnectStub(.immediate(nil))
        let connector = makeConnector(
            stub: stub, maxConnectAttempts: 1, connectRetryDelay: .seconds(2),
            config: makeTestFileProviderConfig())
        connector.startServing(NeverCalledRelay())
        connector.ensureConnected(rootURL: Self.testRootURL)

        try await stub.gate.wait { stub.callCount == 1 && !connector.isConnectingForTesting }
        #expect(!connector.isConnectedForTesting)

        connector.triggerReconnectDoorbellForTesting()

        try await stub.gate.wait { stub.callCount == 2 }
    }
}
