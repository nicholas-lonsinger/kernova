import FileProvider
import Foundation
import os

// Extension-side servicing endpoint for the clipboard File Provider (#460).
//
// Vends an anonymous XPC listener endpoint under the direction's
// `NSFileProviderServiceName`. INVERTED WIRING vs. the old Mach design: the
// *owner* (main app / guest agent) is the XPC **client** and **exports** the
// relay object; this source is the XPC **server** and calls **back** to the
// owner via the accepted connection's `remoteObjectProxy`. There is no Mach
// service — the system hands the owner this endpoint when it calls
// `getFileProviderServicesForItem`.
//
// The extension can't reach its owner on its own, so on `fetchContents` with no
// live owner connection it rings the Darwin doorbell and waits for the owner to
// connect. Crucially the wait is **non-blocking**: `fetchStagedFile` enqueues the
// pull and returns immediately, so the extension's `fetchContents` returns its
// `Progress` without holding a worker thread. This is load-bearing — observed
// empirically (no Apple doc pins it): the File Provider framework serialises
// `supportedServiceSources` / the owner's `getFileProviderConnection` *behind* an
// in-flight `fetchContents`, so a blocking wait here would deadlock the very
// reconnect it is waiting for (the owner could not connect until the wait timed
// out; reproduced on macOS 26). The enqueued pull is drained the instant
// the owner connects; a bounded timer fails it with `serverUnreachable` if the
// owner never appears (not running / domain disabled).

/// One long-lived anonymous-XPC service source for a File Provider extension.
///
/// `@unchecked Sendable`: `acceptedConnection` and `pendingPulls` are guarded by
/// `lock`; `config`/`logger`/`listener`/`queue` are immutable after `init`.
final class FileProviderServiceSource: NSObject, NSFileProviderServiceSource,
    NSXPCListenerDelegate, FileProviderControl, @unchecked Sendable
{
    /// Bounded wait for the owner to connect after the doorbell is rung, kept well
    /// under Finder's ~60 s paste deadline so a missing owner fails cleanly.
    private static let connectTimeout: TimeInterval = 30

    /// Bounded wait for the owner's byte-pull *reply* once a connection is live.
    ///
    /// The XPC error handler only fires on connection failure, not on a live-but-
    /// silent owner (e.g. a stalled vsock pull), so without a bound that pull would
    /// never complete. This runs off Finder's clock (the placeholder already
    /// returned), so it can be generous — long enough for any real pull, finite so
    /// a hung owner can't strand the fetch forever.
    private static let fetchReplyTimeout: TimeInterval = 120

    private let config: FileProviderConfig
    private let logger: Logger
    private let listener: NSXPCListener
    /// Serialises timers and async pull work off the caller's thread.
    private let queue = DispatchQueue(label: "app.kernova.fileprovider.servicesource")

    private let lock = NSLock()
    private var acceptedConnection: NSXPCConnection?
    /// Byte-pulls awaiting a live owner connection, drained on accept.
    private var pendingPulls: [PendingPull] = []

    /// A byte-pull waiting for the owner to connect.
    ///
    /// Reference type so the connect-timeout timer and the accept-time drain can
    /// identify the same pull by identity when racing to claim it from
    /// `pendingPulls` — the lock-guarded removal is the single claim arbiter.
    ///
    /// Genuinely `Sendable`: every stored member is immutable, and `once` is
    /// internally synchronized.
    private final class PendingPull: Sendable {
        let generation: UInt64
        let repIndex: Int
        /// One-shot completion — the single arbiter across every racer that can
        /// finish this pull: the owner's reply, an XPC error, the reply timeout, the
        /// connect timeout, and user cancellation.
        ///
        /// Whoever fires first wins; the rest no-op.
        let once: OnceCompletion

        init(
            generation: UInt64, repIndex: Int,
            completion: @escaping (Result<String, NSError>) -> Void
        ) {
            self.generation = generation
            self.repIndex = repIndex
            self.once = OnceCompletion(completion)
        }
    }

    init(config: FileProviderConfig, logger: Logger) {
        self.config = config
        self.logger = logger
        self.listener = NSXPCListener.anonymous()
        super.init()
        listener.delegate = self
        listener.resume()
    }

    // MARK: - NSFileProviderServiceSource

    var serviceName: NSFileProviderServiceName { config.serviceName }

    /// The clipboard domain is read-only and single-purpose, so it has nothing to
    /// restrict — the owner code-signing pin (below) is the real gate.
    var isRestricted: Bool { false }

    /// Returns the single long-lived anonymous endpoint.
    ///
    /// Reused on every call — minting a fresh listener per connect would dangle
    /// prior connections.
    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        listener.endpoint
    }

    // MARK: - NSXPCListenerDelegate

    /// Accepts the owner's connection, pins it, retains it for `fetchContents`
    /// call-backs, and drains any pulls that were waiting for a connection.
    ///
    /// Fires when the owner sends its `ownerDidConnect()` handshake (an
    /// `NSXPCListener` only delivers this delegate on the client's first message —
    /// hence the handshake; see `FileProviderControl`).
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Bidirectional: we EXPORT the control object (so the owner's handshake
        // lands) and set the relay as our REMOTE interface (so we can call the owner
        // back). The owner mirrors this — exports the relay, remotes the control.
        newConnection.exportedInterface = NSXPCInterface(with: FileProviderControl.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: FileProviderRelay.self)
        // Pin the owner when the direction requires it (the host pins the main
        // app; the guest leaves it nil — see the config doc and #145). Non-throwing:
        // arms a framework-enforced check, so an impostor owner's calls invalidate.
        if let requirement = config.ownerCodeSigningRequirement {
            newConnection.setCodeSigningRequirement(requirement)
        }
        newConnection.invalidationHandler = { [weak self] in self?.clearConnection(newConnection) }
        newConnection.interruptionHandler = { [weak self] in self?.clearConnection(newConnection) }

        // Publish `acceptedConnection` BEFORE resuming, so an invalidation that lands
        // during/just after resume finds the connection current and clears it (rather
        // than `clearConnection` no-op'ing on a not-yet-published connection and
        // leaving a dead one cached — mirrors the owner-side store-before-resume).
        let (previous, drained): (NSXPCConnection?, [PendingPull]) = lock.withLock {
            let prev = acceptedConnection
            acceptedConnection = newConnection
            let waiting = pendingPulls
            pendingPulls = []
            return (prev, waiting)
        }
        newConnection.resume()
        // Defensive: the owner holds one connection at a time and invalidates dropped
        // ones, so a still-live previous is not expected — but if one lingers, release
        // it so an abandoned connection can't leak via its retained handler blocks.
        // Its invalidation handler no-ops (it only clears when still current, and we
        // just replaced it).
        previous?.invalidate()
        logger.debug(
            "Accepted owner servicing connection (draining \(drained.count, privacy: .public) pending)")
        for pull in drained {
            // Each drained pull's connect timer (if armed) fires later and no-ops —
            // the removal from `pendingPulls` above already claimed the pull.
            performPull(over: newConnection, pull: pull)
        }
        return true
    }

    /// Clears the retained connection only if it is still the current one (a newer
    /// connection may already have replaced it).
    private func clearConnection(_ connection: NSXPCConnection) {
        lock.withLock { if acceptedConnection === connection { acceptedConnection = nil } }
    }

    // MARK: - FileProviderControl (activation handshake)

    /// The owner's post-connect handshake.
    ///
    /// Its arrival is what drives `shouldAcceptNewConnection` (already run by the
    /// time this dispatches), so the body only needs to acknowledge — acceptance and
    /// draining happen there.
    func ownerDidConnect(reply: @escaping @Sendable () -> Void) {
        reply()
    }

    // MARK: - Byte pull (called from the extension's fetchContents)

    /// Pulls `(generation, repIndex)` through the owner and completes with the
    /// staged file path or an `NSFileProviderError`.
    ///
    /// **Non-blocking** (see the type doc): completes on the fast path if a
    /// connection is already live, otherwise rings the doorbell, enqueues the pull,
    /// and returns — completing asynchronously when the owner connects or the
    /// bounded `connectTimeout` elapses. `completion` runs exactly once, on an
    /// arbitrary queue.
    func fetchStagedFile(
        generation: UInt64, repIndex: Int,
        completion: @escaping (Result<String, NSError>) -> Void
    ) -> FileProviderPullCancellation {
        let pull = PendingPull(generation: generation, repIndex: repIndex, completion: completion)
        // The cancel handle the extension wires to `fetchContents`' `Progress`. It
        // strongly holds `pull` (but only weakly `self`), so a cancel after this
        // source is gone is a harmless no-op; `cancelPull` funnels through the pull's
        // one-shot, so a cancel racing the real completion can't double-fire.
        let cancellation = FileProviderPullCancellation { [weak self] in
            self?.cancelPull(pull)
        }
        let liveConnection: NSXPCConnection? = lock.withLock {
            if let connection = acceptedConnection { return connection }
            pendingPulls.append(pull)  // enqueue atomically vs. a concurrent accept
            return nil
        }
        if let liveConnection {
            performPull(over: liveConnection, pull: pull)
            return cancellation
        }
        // No live connection: ring the doorbell and arm the bounded connect timeout.
        // The timer holds `pull` weakly so it can't extend the pull's lifetime, and
        // it is never cancelled: if it fires after the pull was drained or
        // cancelled, `failPending`'s lock-guarded claim makes it a no-op.
        logger.notice("No live owner connection — posting reconnect doorbell")
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self, weak pull] in
            guard let self, let pull else { return }
            self.failPending(pull, reason: "owner connect timeout")
        }
        DarwinNotification.post(config.reconnectNotificationName)
        return cancellation
    }

    /// Cancels an in-progress pull — wired to Finder's cancel button through the
    /// `fetchContents` `Progress`.
    ///
    /// Dequeues the pull if it's still waiting for an owner connection, then
    /// completes it once with `NSUserCancelledError`. A no-op if the pull already
    /// finished: the one-shot dedups, and any owner reply still in flight lands
    /// harmlessly on the spent completion. Thread-safe and idempotent.
    ///
    /// This frees the extension's fetch immediately but does **not** abort the
    /// owner's in-flight vsock transfer — a completed-but-unread staged file is left
    /// for the owner's staging cache to evict (tracked as a follow-up).
    private func cancelPull(_ pull: PendingPull) {
        lock.withLock {
            if let index = pendingPulls.firstIndex(where: { $0 === pull }) {
                pendingPulls.remove(at: index)
            }
        }
        if pull.once.fire(.failure(Self.cancelled)) {
            logger.debug("fetchContents pull cancelled by user")
        }
    }

    /// Removes `pull` from the pending queue and fails it once with `serverUnreachable`.
    ///
    /// A no-op if it was already drained by an accept — the lock-guarded removal is
    /// the single arbiter of who completes it.
    private func failPending(_ pull: PendingPull, reason: String) {
        let claimed: Bool = lock.withLock {
            guard let index = pendingPulls.firstIndex(where: { $0 === pull }) else { return false }
            pendingPulls.remove(at: index)
            return true
        }
        guard claimed else { return }
        logger.error("Timed out waiting for owner connection after doorbell (\(reason, privacy: .public))")
        pull.once.fire(.failure(Self.serverUnreachable))
    }

    /// Runs the XPC byte-pull over `connection`, completing `pull` exactly once —
    /// whichever of the reply, the connection error, or the reply timeout fires
    /// first wins.
    private func performPull(over connection: NSXPCConnection, pull: PendingPull) {
        let once = pull.once
        // Bound the reply: a live-but-silent owner never fires the XPC error handler.
        // No cancel token — if the reply or an error arrives first, `OnceCompletion`
        // makes this a harmless no-op when it eventually fires. (A cancellable
        // `DispatchWorkItem` can't be captured in the XPC `@Sendable` closures below.)
        queue.asyncAfter(deadline: .now() + Self.fetchReplyTimeout) {
            once.fire(.failure(Self.serverUnreachable))
        }

        let proxy =
            connection.remoteObjectProxyWithErrorHandler { error in
                once.fire(.failure(error as NSError))
            } as? FileProviderRelay
        guard let proxy else {
            once.fire(.failure(Self.serverUnreachable))
            return
        }
        proxy.fetchFile(generation: pull.generation, repIndex: pull.repIndex) { path, error in
            if let path {
                once.fire(.success(path))
            } else {
                once.fire(.failure(error ?? Self.serverUnreachable))
            }
        }
    }

    private static let serverUnreachable = NSError(
        domain: NSFileProviderErrorDomain, code: NSFileProviderError.serverUnreachable.rawValue)

    /// User-cancelled sentinel — Cocoa's `NSUserCancelledError`, which the File
    /// Provider framework treats as a benign cancellation rather than a fetch
    /// failure, so Finder doesn't surface an error for a paste the user aborted.
    private static let cancelled = NSError(
        domain: NSCocoaErrorDomain, code: NSUserCancelledError)
}

/// Invokes a `(Result<String, NSError>) -> Void` completion exactly once, even when
/// the reply, a connection error, a timeout, and a user cancellation all race to
/// fulfil it.
///
/// `@unchecked Sendable`: the stored completion is guarded by `lock`.
private final class OnceCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<String, NSError>) -> Void)?

    init(_ completion: @escaping (Result<String, NSError>) -> Void) {
        self.completion = completion
    }

    /// Fires the completion if it hasn't fired yet.
    ///
    /// Returns `true` when this call is the one that fired it, `false` if it had
    /// already fired — letting a caller (e.g. cancellation) log only when it actually
    /// won the race.
    @discardableResult
    func fire(_ result: Result<String, NSError>) -> Bool {
        let once: ((Result<String, NSError>) -> Void)? = lock.withLock {
            let pending = completion
            completion = nil
            return pending
        }
        once?(result)
        return once != nil
    }
}

/// A handle that cancels an in-progress `fetchStagedFile` pull.
///
/// Returned by `fetchStagedFile` and wired to the `fetchContents` `Progress`'s
/// `cancellationHandler`, so Finder's cancel button stops the extension waiting on
/// a pull and completes the fetch promptly with `NSUserCancelledError`. `cancel()`
/// is idempotent and safe to call from any thread; a call after the pull has
/// already completed is a no-op.
///
/// Genuinely `Sendable`: the sole stored member is an immutable `@Sendable` closure.
final class FileProviderPullCancellation: Sendable {
    private let onCancel: @Sendable () -> Void

    init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// Requests cancellation of the associated pull.
    func cancel() {
        onCancel()
    }
}
