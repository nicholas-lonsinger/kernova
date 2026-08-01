import Darwin
import FileProvider
import Foundation
import os

// Extension-side servicing endpoint for the clipboard File Provider: vends an
// anonymous XPC listener endpoint under the direction's `NSFileProviderServiceName`.
// The owner (main app / guest agent) is the XPC client and exports the relay; this
// source is the XPC server and calls back over the accepted connection.
// Never block waiting for the owner here: observed empirically on macOS 26 (no Apple
// doc pins it), the framework serialises the owner's `getFileProviderConnection`
// behind an in-flight `fetchContents`, so a blocking wait deadlocks the very
// reconnect it is waiting for.

/// One long-lived anonymous-XPC service source for a File Provider extension.
///
/// `@unchecked Sendable`: `acceptedConnection`, `pendingPulls`, and `invalidated`
/// are guarded by `lock`; everything else is immutable after `init`.
final class FileProviderServiceSource: NSObject, NSFileProviderServiceSource,
    NSXPCListenerDelegate, FileProviderControl, @unchecked Sendable
{
    /// Bounded wait for the owner to connect after the doorbell is rung, kept well
    /// under Finder's ~60 s paste deadline so a missing owner fails cleanly.
    private let connectTimeout: TimeInterval

    /// Bounded wait for the owner's byte-pull *reply* once a connection is live.
    ///
    /// The XPC error handler only fires on connection failure, not on a live-but-
    /// silent owner (e.g. a stalled vsock pull), so without a bound that pull would
    /// never complete. It runs off Finder's clock — the placeholder already
    /// returned — so it can be generous.
    private let fetchReplyTimeout: TimeInterval

    private let config: FileProviderConfig
    private let logger: Logger
    private let listener: NSXPCListener
    /// Serialises timers and async pull work off the caller's thread.
    private let queue = DispatchQueue(label: "app.kernova.fileprovider.servicesource")

    private let lock = NSLock()
    private var acceptedConnection: NSXPCConnection?
    /// Byte-pulls awaiting a live owner connection, drained on accept.
    private var pendingPulls: [PendingPull] = []
    /// Set once the owning extension instance is invalidated: refuses new
    /// connections and fast-fails any pull that races the teardown, so a pull
    /// landing on this dead source can't hang the full `connectTimeout`.
    private var invalidated = false

    /// What a pending pull addresses: a flat single-file rep, or one child file
    /// of a directory rep's placeholder tree.
    private enum PullTarget {
        case flat
        case child(childSeq: UInt32, relativePath: String)
    }

    /// A byte-pull waiting for the owner to connect.
    ///
    /// Reference type so the connect-timeout timer and the accept-time drain can
    /// identify the same pull by identity when racing to claim it from
    /// `pendingPulls` — the lock-guarded removal is the single claim arbiter.
    private final class PendingPull: Sendable {
        let generation: UInt64
        let repIndex: Int
        let target: PullTarget
        let once: OnceCompletion

        init(
            generation: UInt64, repIndex: Int, target: PullTarget,
            completion: @escaping (Result<String, NSError>) -> Void
        ) {
            self.generation = generation
            self.repIndex = repIndex
            self.target = target
            self.once = OnceCompletion(completion)
        }
    }

    init(
        config: FileProviderConfig, logger: Logger,
        connectTimeout: TimeInterval = FileProviderServicingTiming.connectWait,
        fetchReplyTimeout: TimeInterval = FileProviderServicingTiming.fetchReplyWait
    ) {
        self.config = config
        self.logger = logger
        self.connectTimeout = connectTimeout
        self.fetchReplyTimeout = fetchReplyTimeout
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

    /// Accepts the owner's connection, pins it, and drains any pulls that were
    /// waiting for a connection.
    ///
    /// Fires when the owner sends its `ownerDidConnect()` handshake — an
    /// `NSXPCListener` only delivers this delegate on the client's first message.
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: FileProviderControl.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: FileProviderRelay.self)
        // Non-throwing: arms a framework-enforced check, so an impostor owner's
        // calls invalidate rather than failing here.
        if let requirement = config.ownerCodeSigningRequirement {
            if #available(macOS 13.0, *) {
                newConnection.setCodeSigningRequirement(requirement)
            } else {
                // Unreachable in practice: the only pre-13 process is the guest
                // agent, and `FileProviderConfig.guest()` supplies no requirement.
                logger.fault("Code-signing requirement configured but unenforceable below macOS 13")
                assertionFailure("Code-signing requirement configured but unenforceable below macOS 13")
            }
        }
        newConnection.invalidationHandler = { [weak self] in self?.clearConnection(newConnection) }
        newConnection.interruptionHandler = { [weak self] in self?.clearConnection(newConnection) }

        // Publish `acceptedConnection` BEFORE resuming, so an invalidation landing
        // during resume finds the connection current and clears it rather than
        // no-op'ing and leaving a dead connection cached.
        let accepted: (previous: NSXPCConnection?, drained: [PendingPull])? = lock.withLock {
            // Don't publish or resume a connection this dead source will never service.
            if invalidated { return nil }
            let prev = acceptedConnection
            acceptedConnection = newConnection
            let waiting = pendingPulls
            pendingPulls = []
            return (prev, waiting)
        }
        guard let accepted else { return false }
        let (previous, drained) = accepted
        newConnection.resume()
        // A lingering previous connection would leak via its retained handler
        // blocks. Its invalidation handler no-ops — we just replaced it.
        previous?.invalidate()
        // The peer pin covers only bundle identifier + team, so log which copy of
        // the owner actually connected.
        let peerPID = newConnection.processIdentifier
        logger.notice(
            "\(Self.acceptedOwnerLogLine(pid: peerPID, executablePath: Self.executablePath(forPID: peerPID), pendingCount: drained.count), privacy: .public)"
        )
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

    /// Tears the source down when the owning extension instance is invalidated.
    ///
    /// fileproviderd invalidates and re-instantiates the `FileProviderExtension` —
    /// sometimes within the same process — when the clipboard toggle flips. Without
    /// this teardown the owner keeps re-handshaking with the dead instance and every
    /// pull burns the full `connectTimeout`. Must stay idempotent:
    /// `NSXPCConnection.invalidate()` is documented safe to repeat but
    /// `NSXPCListener`'s is not, and the framework may call this more than once.
    func invalidate() {
        let teardown: (connection: NSXPCConnection?, drained: [PendingPull])? = lock.withLock {
            guard !invalidated else { return nil }
            invalidated = true
            let connection = acceptedConnection
            acceptedConnection = nil
            let pulls = pendingPulls
            pendingPulls = []
            return (connection, pulls)
        }
        guard let teardown else { return }
        listener.invalidate()
        teardown.connection?.invalidate()
        for pull in teardown.drained {
            pull.once.fire(.failure(Self.serverUnreachable))
        }
    }

    /// Formats the accept-time owner-identity log line — pure, so tests need no
    /// XPC round trip.
    static func acceptedOwnerLogLine(pid: pid_t, executablePath: String?, pendingCount: Int) -> String {
        "Accepted owner servicing connection (pid=\(pid) executable=\(executablePath ?? "unknown") draining \(pendingCount) pending)"
    }

    /// Best-effort resolution of a process's executable path via `proc_pidpath`.
    ///
    /// `nil` on failure — the peer may have exited, and the App Sandbox may scope
    /// `proc_pidpath` to the caller's own PID. Callers fall back to the PID alone.
    /// Not `NSRunningApplication`: this file compiles into two File Provider
    /// extension binaries, neither an AppKit app.
    private static func executablePath(forPID pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` itself is unavailable on this SDK
        // ("structure not supported"); its definition (4 * MAXPATHLEN) is not,
        // so compute the same bound directly.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    // MARK: - FileProviderControl (activation handshake)

    /// The owner's post-connect handshake.
    ///
    /// Its arrival is what drives `shouldAcceptNewConnection`, already run by the
    /// time this dispatches — so the body only needs to acknowledge.
    func ownerDidConnect(reply: @escaping @Sendable () -> Void) {
        reply()
    }

    // MARK: - Byte pull (called from the extension's fetchContents)

    /// Pulls `(generation, repIndex)` through the owner and completes with the
    /// staged file path or an `NSFileProviderError`.
    ///
    /// Non-blocking (see the file header): returns after enqueueing, completing when
    /// the owner connects or `connectTimeout` elapses. `completion` runs exactly
    /// once, on an arbitrary queue.
    func fetchStagedFile(
        generation: UInt64, repIndex: Int,
        completion: @escaping (Result<String, NSError>) -> Void
    ) -> FileProviderPullCancellation {
        enqueue(generation: generation, repIndex: repIndex, target: .flat, completion: completion)
    }

    /// Pulls one child file of a directory rep's placeholder tree, addressed by
    /// `(generation, repIndex, childSeq, relativePath)`.
    ///
    /// Same non-blocking, one-shot, doorbell-and-timeout semantics as
    /// `fetchStagedFile`.
    func fetchStagedChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
        completion: @escaping (Result<String, NSError>) -> Void
    ) -> FileProviderPullCancellation {
        enqueue(
            generation: generation, repIndex: repIndex,
            target: .child(childSeq: childSeq, relativePath: relativePath), completion: completion)
    }

    private func enqueue(
        generation: UInt64, repIndex: Int, target: PullTarget,
        completion: @escaping (Result<String, NSError>) -> Void
    ) -> FileProviderPullCancellation {
        let pull = PendingPull(
            generation: generation, repIndex: repIndex, target: target, completion: completion)
        // Holds `pull` strongly but `self` weakly, so a cancel after this source is
        // gone is a harmless no-op.
        let cancellation = FileProviderPullCancellation { [weak self] in
            self?.cancelPull(pull)
        }
        let (isInvalidated, liveConnection): (Bool, NSXPCConnection?) = lock.withLock {
            // Fast-fail rather than enqueue a pull that would hang the full
            // `connectTimeout` against a dead source.
            if invalidated { return (true, nil) }
            if let connection = acceptedConnection { return (false, connection) }
            pendingPulls.append(pull)  // enqueue atomically vs. a concurrent accept
            return (false, nil)
        }
        if isInvalidated {
            pull.once.fire(.failure(Self.serverUnreachable))
            return cancellation
        }
        if let liveConnection {
            performPull(over: liveConnection, pull: pull)
            return cancellation
        }
        // The connect timer is never cancelled: if it fires after the pull was
        // drained or cancelled, `failPending`'s lock-guarded claim makes it a no-op.
        logger.notice("No live owner connection — posting reconnect doorbell")
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self, weak pull] in
            guard let self, let pull else { return }
            self.failPending(pull, reason: "owner connect timeout")
        }
        DarwinNotification.post(config.reconnectNotificationName)
        return cancellation
    }

    /// Cancels an in-progress pull, wired to Finder's cancel button through the
    /// `fetchContents` `Progress`.
    ///
    /// Thread-safe, idempotent, and a no-op once the pull has finished. The owner is
    /// asked to abort its in-flight vsock transfer only when this call actually wins
    /// the race to resolve the pull: a pull absent from `pendingPulls` may already
    /// have succeeded or timed out, and a phantom `cancelFetch` could abort an
    /// unrelated later pull reusing the same deterministic transferID.
    private func cancelPull(_ pull: PendingPull) {
        let dispatchedTo: NSXPCConnection? = lock.withLock {
            if let index = pendingPulls.firstIndex(where: { $0 === pull }) {
                pendingPulls.remove(at: index)
                return nil  // Never sent to the owner — nothing to abort there.
            }
            return acceptedConnection
        }
        let wonRace = pull.once.fire(.failure(Self.cancelled))
        if wonRace {
            logger.debug("fetchContents pull cancelled by user")
        }
        if wonRace, let dispatchedTo {
            let relay = dispatchedTo.remoteObjectProxy as? FileProviderRelay
            switch pull.target {
            case .flat:
                relay?.cancelFetch(generation: pull.generation, repIndex: pull.repIndex)
            case .child(let childSeq, _):
                relay?.cancelChildFetch(
                    generation: pull.generation, repIndex: pull.repIndex, childSeq: childSeq)
            }
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
        // Never cancelled — `OnceCompletion` makes a late fire a no-op.
        queue.asyncAfter(deadline: .now() + fetchReplyTimeout) {
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
        let reply: @Sendable (String?, NSError?) -> Void = { path, error in
            if let path {
                once.fire(.success(path))
            } else {
                once.fire(.failure(error ?? Self.serverUnreachable))
            }
        }
        switch pull.target {
        case .flat:
            proxy.fetchFile(generation: pull.generation, repIndex: pull.repIndex, reply: reply)
        case .child(let childSeq, let relativePath):
            proxy.fetchChild(
                generation: pull.generation, repIndex: pull.repIndex, childSeq: childSeq,
                relativePath: relativePath, reply: reply)
        }
    }

    private static let serverUnreachable = NSError(
        domain: NSFileProviderErrorDomain, code: NSFileProviderError.serverUnreachable.rawValue)

    /// User-cancelled sentinel: the File Provider framework treats
    /// `NSUserCancelledError` as a benign cancellation rather than a fetch failure,
    /// so Finder surfaces no error for a paste the user aborted.
    private static let cancelled = NSError(
        domain: NSCocoaErrorDomain, code: NSUserCancelledError)

    #if DEBUG
    /// Number of byte-pulls currently queued awaiting an owner connection.
    var pendingPullCountForTesting: Int { lock.withLock { pendingPulls.count } }
    #endif
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
    /// Returns `true` when this call is the one that fired it — letting a caller
    /// act only when it actually won the race.
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
/// Wired to the `fetchContents` `Progress`'s `cancellationHandler`. `cancel()` is
/// idempotent, safe from any thread, and a no-op once the pull has completed.
final class FileProviderPullCancellation: Sendable {
    private let onCancel: @Sendable () -> Void

    init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }
}
