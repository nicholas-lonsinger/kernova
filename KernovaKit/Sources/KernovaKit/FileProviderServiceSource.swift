import Darwin
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
// `NSFileProviderManager.getService(named:for:)`.
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
/// `@unchecked Sendable`: `acceptedConnection`, `pendingPulls`, and `invalidated`
/// are guarded by `lock`; `config`/`logger`/`listener`/`queue` are immutable
/// after `init`.
final class FileProviderServiceSource: NSObject, NSFileProviderServiceSource,
    NSXPCListenerDelegate, FileProviderControl, @unchecked Sendable
{
    /// Bounded wait for the owner to connect after the doorbell is rung, kept well
    /// under Finder's ~60 s paste deadline so a missing owner fails cleanly.
    ///
    /// Defaults to `FileProviderServicingTiming.connectWait` — the source of
    /// truth the owner's `FileProviderServicingConnector` reconnect budget is
    /// structurally derived from (#466), so the two sides cannot drift apart.
    private let connectTimeout: TimeInterval

    /// Bounded wait for the owner's byte-pull *reply* once a connection is live.
    ///
    /// The XPC error handler only fires on connection failure, not on a live-but-
    /// silent owner (e.g. a stalled vsock pull), so without a bound that pull would
    /// never complete. This runs off Finder's clock (the placeholder already
    /// returned), so it can be generous — long enough for any real pull, finite so
    /// a hung owner can't strand the fetch forever.
    ///
    /// Defaults to `FileProviderServicingTiming.fetchReplyWait` — the source of
    /// truth tests reference instead of independently re-hardcoding the value.
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
    /// Set once the owning extension instance is invalidated (#598): refuses new
    /// connections and fast-fails any pull that races the teardown, so a pull
    /// landing on this dead source can't hang the full `connectTimeout`.
    private var invalidated = false

    /// In-flight progress handlers keyed by `(generation, repIndex)` (#426).
    ///
    /// An owner `fetchProgressed` push during a live pull reaches that pull's
    /// `Progress` through this map. Registered by `fetchStagedFile` when the pull
    /// starts, removed when it completes — a late push for a finished pull finds no
    /// handler and no-ops.
    ///
    /// Each entry carries a monotonic `token` so a pull's completion only removes
    /// *its own* registration: if a same-`(generation, repIndex)` retry re-registered
    /// (the #500 supersession edge), the displaced pull's completion must not evict
    /// the successor's handler.
    private var progressHandlers: [ProgressKey: ProgressRegistration] = [:]
    private var nextProgressToken: UInt64 = 0

    /// Addresses one in-flight pull's progress handler — the same
    /// `(generation, repIndex, childSeq)` the owner keys its progress push on
    /// (`childSeq == 0` for a flat rep; `>= 1` for a directory rep's file node,
    /// so a folder's concurrent child pulls each key distinctly — folder D1b).
    private struct ProgressKey: Hashable {
        let generation: UInt64
        let repIndex: Int
        let childSeq: UInt32
    }

    /// What a pending pull addresses: a flat single-file rep, or one child file
    /// of a directory rep's placeholder tree (folder D1b).
    private enum PullTarget {
        case flat
        case child(childSeq: UInt32, relativePath: String)

        /// `childSeq` for the progress key — `0` for a flat rep.
        var childSeq: UInt32 {
            if case .child(let childSeq, _) = self { return childSeq }
            return 0
        }
    }

    /// A registered progress handler plus the token that identifies its pull.
    private struct ProgressRegistration {
        let token: UInt64
        let handler: @Sendable (UInt64, UInt64) -> Void
    }

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
        /// What this pull addresses (a flat rep or a directory-tree child).
        let target: PullTarget
        /// One-shot completion — the single arbiter across every racer that can
        /// finish this pull: the owner's reply, an XPC error, the reply timeout, the
        /// connect timeout, and user cancellation.
        ///
        /// Whoever fires first wins; the rest no-op.
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
        let accepted: (previous: NSXPCConnection?, drained: [PendingPull])? = lock.withLock {
            // Refuse once the instance is invalidated: don't publish or resume a
            // connection this dead source will never service (#598).
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
        // Defensive: the owner holds one connection at a time and invalidates dropped
        // ones, so a still-live previous is not expected — but if one lingers, release
        // it so an abandoned connection can't leak via its retained handler blocks.
        // Its invalidation handler no-ops (it only clears when still current, and we
        // just replaced it).
        previous?.invalidate()
        // Identity signal at the XPC choke point (#518): the peer pin above checks
        // only bundle identifier + team, so a version-mismatched owner (an old
        // resident copy still answering after a new one was installed) would
        // otherwise be accepted with no clue in this process's log as to which
        // copy connected — diagnosable only by correlating logs across
        // processes. `.notice` (not `.debug`) so the line actually persists for
        // that post-mortem — accepts are infrequent (one per owner connect), so
        // persisting them is cheap. Mirrors `AppDelegate.residentProvenanceLine`
        // (#519), the complementary owner-side startup provenance line.
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
    /// fileproviderd invalidates and re-instantiates the `FileProviderExtension`
    /// — including replacing it within the same process — when the File Provider
    /// toggle flips. Without this teardown the invalidated instance's accepted
    /// connection stays alive (retained by the owner's live XPC connection), so
    /// the owner never sees a drop and keeps re-handshaking with this zombie;
    /// every subsequent pull then times out the full `connectTimeout` against a
    /// source whose extension is gone (#598). Invalidating the accepted
    /// connection here fires the owner's invalidation handler, driving its
    /// reconnect to the *current* instance's listener.
    ///
    /// Drops the listener and accepted connection and fails every pending pull
    /// once with `serverUnreachable` (their wrapped completions unregister the
    /// progress handlers; `OnceCompletion` dedups against the never-cancelled
    /// connect timers). `invalidated` — set under `lock` first — then fast-fails
    /// any pull that lands between here and process teardown and refuses new
    /// connections.
    /// Idempotent: only the first call owns the teardown. `NSXPCConnection`'s
    /// `invalidate()` is documented safe to repeat, but `NSXPCListener`'s carries
    /// no such guarantee, so the claim below is what keeps a second
    /// `FileProviderExtension.invalidate()` (the framework does not promise to
    /// call it exactly once) from re-invalidating the listener.
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

    /// Formats the accept-time owner-identity log line — pure and testable
    /// without standing up an XPC round trip, mirroring
    /// `AppDelegate.residentProvenanceLine` (#519).
    static func acceptedOwnerLogLine(pid: pid_t, executablePath: String?, pendingCount: Int) -> String {
        "Accepted owner servicing connection (pid=\(pid) executable=\(executablePath ?? "unknown") draining \(pendingCount) pending)"
    }

    /// Best-effort resolution of a process's executable path via `proc_pidpath`.
    ///
    /// `nil` on failure (e.g. the peer exited between accept and this call, or
    /// the App Sandbox denies resolving a non-self PID — both extension
    /// targets this file compiles into carry `com.apple.security.app-sandbox`,
    /// and Apple's sandbox profile may scope `proc_pidpath` to the caller's own
    /// PID). Either way this is best-effort: callers fall back to logging just
    /// the PID — the primary, always-available identity signal — rather than
    /// treating an unresolved path as fatal. Deliberately not
    /// `NSRunningApplication`, which pulls AppKit into this file — shared
    /// `KernovaKit` code compiled into both the host and guest File Provider
    /// *extension* binaries, neither an AppKit app.
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
    /// Its arrival is what drives `shouldAcceptNewConnection` (already run by the
    /// time this dispatches), so the body only needs to acknowledge — acceptance and
    /// draining happen there.
    func ownerDidConnect(reply: @escaping @Sendable () -> Void) {
        reply()
    }

    /// The owner's byte-progress push for an in-flight pull (#426): routes it to
    /// the pull's registered handler, or no-ops when none is registered.
    ///
    /// A no-op for an unknown or already-finished `(generation, repIndex)` — the
    /// handler is removed the instant the pull completes, so a push racing (or
    /// arriving after) the terminal harmlessly finds nothing. The handler is read
    /// under `lock` and invoked outside it (it only advances an `NSProgress`).
    func fetchProgressed(
        generation: UInt64, repIndex: Int, bytesTransferred: UInt64, totalBytes: UInt64
    ) {
        routeProgress(
            key: ProgressKey(generation: generation, repIndex: repIndex, childSeq: 0),
            bytesTransferred: bytesTransferred, totalBytes: totalBytes)
    }

    func childFetchProgressed(
        generation: UInt64, repIndex: Int, childSeq: UInt32, bytesTransferred: UInt64,
        totalBytes: UInt64
    ) {
        routeProgress(
            key: ProgressKey(generation: generation, repIndex: repIndex, childSeq: childSeq),
            bytesTransferred: bytesTransferred, totalBytes: totalBytes)
    }

    /// Routes an owner progress push to the keyed pull's registered handler, or
    /// no-ops when none is registered (a late push for a finished pull).
    private func routeProgress(key: ProgressKey, bytesTransferred: UInt64, totalBytes: UInt64) {
        let handler = lock.withLock { progressHandlers[key]?.handler }
        handler?(bytesTransferred, totalBytes)
    }

    /// Removes a pull's progress handler, but only if it's still the same
    /// registration (`token` match) — so a displaced pull's completion can't evict
    /// a same-key retry's handler (the #500 supersession edge).
    private func unregisterProgress(key: ProgressKey, token: UInt64) {
        lock.withLock {
            if progressHandlers[key]?.token == token { progressHandlers[key] = nil }
        }
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
        onProgress: @escaping @Sendable (_ bytesTransferred: UInt64, _ totalBytes: UInt64) -> Void =
            { _, _ in },
        completion: @escaping (Result<String, NSError>) -> Void
    ) -> FileProviderPullCancellation {
        enqueue(
            generation: generation, repIndex: repIndex, target: .flat, onProgress: onProgress,
            completion: completion)
    }

    /// Pulls one child file of a directory rep's placeholder tree (folder D1b),
    /// addressed by `(generation, repIndex, childSeq, relativePath)`.
    ///
    /// Same
    /// non-blocking, one-shot, doorbell-and-timeout semantics as
    /// `fetchStagedFile`.
    func fetchStagedChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
        onProgress: @escaping @Sendable (_ bytesTransferred: UInt64, _ totalBytes: UInt64) -> Void =
            { _, _ in },
        completion: @escaping (Result<String, NSError>) -> Void
    ) -> FileProviderPullCancellation {
        enqueue(
            generation: generation, repIndex: repIndex,
            target: .child(childSeq: childSeq, relativePath: relativePath), onProgress: onProgress,
            completion: completion)
    }

    /// Shared body of `fetchStagedFile`/`fetchStagedChild`: registers the pull's
    /// progress handler, enqueues (or fast-paths) the pull, and returns its
    /// cancellation handle.
    private func enqueue(
        generation: UInt64, repIndex: Int, target: PullTarget,
        onProgress: @escaping @Sendable (_ bytesTransferred: UInt64, _ totalBytes: UInt64) -> Void,
        completion: @escaping (Result<String, NSError>) -> Void
    ) -> FileProviderPullCancellation {
        // Register the progress handler for the pull's lifetime and wrap the
        // completion so it is removed exactly once, on whichever terminal wins the
        // pull's one-shot. A late progress push after this finds no handler.
        let progressKey = ProgressKey(
            generation: generation, repIndex: repIndex, childSeq: target.childSeq)
        let progressToken: UInt64 = lock.withLock {
            nextProgressToken &+= 1
            let token = nextProgressToken
            progressHandlers[progressKey] = ProgressRegistration(token: token, handler: onProgress)
            return token
        }
        let completion: (Result<String, NSError>) -> Void = { [weak self] result in
            self?.unregisterProgress(key: progressKey, token: progressToken)
            completion(result)
        }
        let pull = PendingPull(
            generation: generation, repIndex: repIndex, target: target, completion: completion)
        // The cancel handle the extension wires to `fetchContents`' `Progress`. It
        // strongly holds `pull` (but only weakly `self`), so a cancel after this
        // source is gone is a harmless no-op; `cancelPull` funnels through the pull's
        // one-shot, so a cancel racing the real completion can't double-fire.
        let cancellation = FileProviderPullCancellation { [weak self] in
            self?.cancelPull(pull)
        }
        let (isInvalidated, liveConnection): (Bool, NSXPCConnection?) = lock.withLock {
            // The instance is gone — fast-fail rather than enqueue a pull that
            // would hang the full `connectTimeout` against a dead source (#598).
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
        // No live connection: ring the doorbell and arm the bounded connect timeout.
        // The timer holds `pull` weakly so it can't extend the pull's lifetime, and
        // it is never cancelled: if it fires after the pull was drained or
        // cancelled, `failPending`'s lock-guarded claim makes it a no-op.
        logger.notice("No live owner connection — posting reconnect doorbell")
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self, weak pull] in
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
    /// This frees the extension's fetch immediately. If the pull had already been
    /// dispatched to the owner (vs. still waiting for a connection) AND this call
    /// is the one that actually wins the race to resolve it, also asks the owner
    /// to abort its in-flight vsock transfer (#464) via `cancelFetch` — a
    /// one-way, best-effort call the owner's relay can now receive even while its
    /// `fetchFile` for this same pull is still in flight (see `FileProviderRelay`'s
    /// doc on the shared serial delivery queue).
    ///
    /// Gating on the race win matters: a pull absent from `pendingPulls` isn't
    /// necessarily still in flight at the owner — it may have already succeeded
    /// via the fast path in `fetchStagedFile`, or already failed via
    /// `failPending`'s connect timeout, either of which resolves `pull.once`
    /// before this call ever runs. Without the gate, a late/duplicate cancel in
    /// either state would send a phantom `cancelFetch` for a `(generation,
    /// repIndex)` the owner never received (or already finished) a `fetchFile`
    /// for — which could spuriously abort an unrelated later pull that reuses
    /// the same deterministic transferID.
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
        // No cancel token — if the reply or an error arrives first, `OnceCompletion`
        // makes this a harmless no-op when it eventually fires. (A cancellable
        // `DispatchWorkItem` can't be captured in the XPC `@Sendable` closures below.)
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

    /// User-cancelled sentinel — Cocoa's `NSUserCancelledError`, which the File
    /// Provider framework treats as a benign cancellation rather than a fetch
    /// failure, so Finder doesn't surface an error for a paste the user aborted.
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
