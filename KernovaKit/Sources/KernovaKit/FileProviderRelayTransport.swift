import FileProvider
import Foundation

// How the domain host connects to the sandboxed extension to serve its relay
// (issues #376 guest / #424 host / #460 servicing migration).
//
// Both directions use the canonical `NSFileProviderServicing` anonymous-XPC
// pattern. INVERTED wiring vs. the old Mach design: the *owner* (the guest agent
// or the main app) is the XPC **client** — it reaches the extension's vended
// endpoint via `FileManager.getFileProviderServicesForItem(at:)` →
// `NSFileProviderService.getFileProviderConnection`, then **exports** the relay
// object so the extension can call it back at `fetchContents`. The extension can
// neither initiate nor launch a connection, so the owner connects proactively at
// publish time and re-connects when the extension rings the Darwin doorbell.
//
// The domain host owns the relay *service* (built from its pull provider) and
// hands it to the connector, keeping its enable/disable lifecycle identical
// across directions. Host and guest now share ONE connector implementation —
// the only differences (service name, doorbell name, code-signing pins) come
// from `FileProviderConfig`.

/// Connects the domain host to its File Provider extension so the extension can
/// call the relay back.
///
/// Injected into `FileProviderDomainHost`; the default is a
/// `FileProviderServicingConnector`, and tests inject a no-op.
public protocol FileProviderRelayTransport: AnyObject, Sendable {
    /// Arms the connector with the relay `service` to export, and starts
    /// listening for the reconnect doorbell. Idempotent — called on each enable.
    func startServing(_ service: FileProviderRelay)

    /// Disarms the connector (clipboard sharing disabled): clears the served
    /// relay, drops any live connection, and stops observing the doorbell so a
    /// call made while disabled can't reach a stale relay.
    func stopServing()

    /// Proactively (re)establishes the control connection to the extension that
    /// manages `rootURL` — the domain root user-visible URL (never a dataless
    /// file placeholder, which could deadlock; see #460). Idempotent: a live or
    /// in-flight connection short-circuits. Runs the connect off the caller's
    /// thread so it can't block.
    func ensureConnected(rootURL: URL)
}

// MARK: - Servicing connector

/// The single `FileProviderRelayTransport` implementation: reaches the
/// extension's `NSFileProviderServicing` endpoint, exports the relay, and keeps
/// the control connection warm (reconnecting on the Darwin doorbell or an XPC
/// invalidation).
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; the immutable
/// addressing/logging values are set once in `init`. The exported relay carries
/// no bytes — only `(generation, repIndex)` crosses, and the reply is a staged
/// app-group path.
public final class FileProviderServicingConnector: NSObject,
    FileProviderRelayTransport, @unchecked Sendable
{
    /// Establishes the control connection to the extension.
    ///
    /// Production performs the `getFileProviderServicesForItem` →
    /// `NSFileProviderService.getFileProviderConnection` dance (logging each
    /// failure); tests inject a stub yielding a controllable connection or `nil`.
    /// The seam collapses both system calls into one closure rather than
    /// injecting either individually: `NSFileProviderService` is an opaque,
    /// non-instantiable system type a test can't fabricate.
    typealias ConnectOperation =
        @Sendable (_ rootURL: URL, _ completion: @escaping @Sendable (NSXPCConnection?) -> Void) -> Void

    private let reconnectNotificationName: String
    private let extensionRequirement: String?
    private let logger: KernovaLogger
    private let connectOperation: ConnectOperation
    /// Serializes the connect handshake and the doorbell handler off the main
    /// queue (the connect must never block the owner's main actor).
    private let queue = DispatchQueue(label: "app.kernova.fileprovider.connector")

    private let lock = NSLock()
    /// The relay object exported to the extension; `nil` while disabled.
    private var relayService: FileProviderRelay?
    /// The domain root URL to connect through, cached from `ensureConnected`.
    private var rootURL: URL?
    /// The live control connection, or `nil` when not connected.
    private var connection: NSXPCConnection?
    /// `true` while a connect handshake is in flight (coalesces concurrent
    /// attempts).
    private var connecting = false
    /// Observes the reconnect doorbell while armed.
    private var reconnectObserver: DarwinNotificationObserver?
    /// Consecutive failed connect attempts in the current retry burst.
    ///
    /// Reset on a successful connect, on a live connection dropping, and on any
    /// external (re)connect trigger; incremented on each transient failure. Bounds
    /// the retry loop so a permanently unreachable extension can't spin.
    private var connectAttempts = 0

    /// Upper bound on transient connect retries before giving up.
    ///
    /// Sized (via `defaultMaxConnectAttempts`/`defaultConnectRetryDelay`) so
    /// `maxConnectAttempts × connectRetryDelay` (~30 s) spans the extension's own
    /// `fetchContents` connect wait, so a slow-relaunching extension is still
    /// caught within the window the paste is waiting — rather than the owner
    /// giving up after a few seconds while the extension keeps waiting. (#466
    /// tracks making this coupling more explicit.)
    private let maxConnectAttempts: Int
    /// Delay between transient connect retries.
    private let connectRetryDelay: DispatchTimeInterval

    /// Production default for `maxConnectAttempts` — see its doc for the ~30s
    /// coupling with the extension's connect-timeout.
    private static let defaultMaxConnectAttempts = 15
    /// Production default for `connectRetryDelay` — see its doc for the ~30s
    /// coupling with the extension's connect-timeout.
    private static let defaultConnectRetryDelay: DispatchTimeInterval = .seconds(2)

    /// Creates a connector for one direction from its config.
    public convenience init(config: FileProviderConfig) {
        // Built self-free from `config`'s VALUES: `connectOperation` is a stored
        // `let` that must be assigned before the delegated init runs, before which
        // a closure cannot capture `self`.
        let logger = KernovaLogger(
            subsystem: config.loggerSubsystem, category: "ServicingConnector")
        let serviceName = config.serviceName
        let operation: ConnectOperation = { rootURL, completion in
            // Root is a real directory (never a dataless file placeholder) so this
            // can't trigger reentrant materialization → deadlock (P1b, #460).
            FileManager.default.getFileProviderServicesForItem(at: rootURL) { services, error in
                if let error {
                    logger.error(
                        "getFileProviderServicesForItem failed: \(error.localizedDescription, privacy: .public)"
                    )
                    completion(nil)
                    return
                }
                guard let service = services?[serviceName] else {
                    logger.error(
                        "Servicing endpoint '\(serviceName.rawValue, privacy: .public)' not offered by the extension"
                    )
                    completion(nil)
                    return
                }
                service.getFileProviderConnection { connection, error in
                    guard let connection else {
                        logger.error(
                            "getFileProviderConnection failed: \(error?.localizedDescription ?? "nil connection", privacy: .public)"
                        )
                        completion(nil)
                        return
                    }
                    completion(connection)
                }
            }
        }
        self.init(
            config: config, connect: operation,
            maxConnectAttempts: Self.defaultMaxConnectAttempts,
            connectRetryDelay: Self.defaultConnectRetryDelay, logger: logger)
    }

    /// Creates a connector with an injected connect operation and retry budget —
    /// the seam tests use to drive the state machine deterministically.
    ///
    /// `logger` lets the convenience init above pass through the logger it
    /// already built for the default `connect` closure, rather than this
    /// initializer constructing a second, redundant `KernovaLogger` from the
    /// same config; test call sites omit it and get one built from `config`.
    init(
        config: FileProviderConfig, connect: @escaping ConnectOperation,
        maxConnectAttempts: Int, connectRetryDelay: DispatchTimeInterval,
        logger: KernovaLogger? = nil
    ) {
        self.reconnectNotificationName = config.reconnectNotificationName
        self.extensionRequirement = config.extensionCodeSigningRequirement
        self.logger =
            logger
            ?? KernovaLogger(subsystem: config.loggerSubsystem, category: "ServicingConnector")
        self.connectOperation = connect
        self.maxConnectAttempts = maxConnectAttempts
        self.connectRetryDelay = connectRetryDelay
        super.init()
    }

    // MARK: - FileProviderRelayTransport

    /// Arms the connector with the relay to export and starts observing the
    /// reconnect doorbell.
    public func startServing(_ service: FileProviderRelay) {
        lock.withLock {
            self.relayService = service
            if reconnectObserver == nil {
                reconnectObserver = DarwinNotificationObserver(
                    name: reconnectNotificationName, queue: queue
                ) { [weak self] in
                    self?.handleReconnectDoorbell()
                }
            }
        }
        logger.notice("Servicing connector armed (relay set; doorbell observer active)")
    }

    /// Disarms the connector: clears the relay, drops the connection, and stops
    /// observing the doorbell.
    public func stopServing() {
        let dropped: NSXPCConnection? = lock.withLock {
            self.relayService = nil
            reconnectObserver?.cancel()
            reconnectObserver = nil
            let live = self.connection
            self.connection = nil
            return live
        }
        dropped?.invalidate()
        logger.notice("Servicing connector disarmed (clipboard disabled)")
    }

    /// Caches the domain root URL and proactively (re)establishes the control
    /// connection if not already connected.
    public func ensureConnected(rootURL: URL) {
        // An explicit (re)connect request restarts the retry budget.
        lock.withLock {
            self.rootURL = rootURL
            connectAttempts = 0
        }
        connectIfNeeded()
    }

    // MARK: - Connection lifecycle

    private func handleReconnectDoorbell() {
        logger.notice("Reconnect doorbell received")
        // The doorbell means the extension has no accepted connection. Reset the
        // retry budget (it's actively waiting on us) and act on our cached state:
        let existing: NSXPCConnection? = lock.withLock {
            connectAttempts = 0
            return self.connection
        }
        if let existing {
            // We think we're connected. Re-send the activation handshake rather than
            // tearing the connection down: on a live connection it's a harmless
            // re-acknowledge, and on a secretly-dead one the handshake's error
            // handler drops it and reconnects. This avoids killing a healthy
            // connection whose just-drained pulls are mid-flight.
            activate(existing)
        } else {
            connectIfNeeded()
        }
    }

    /// Claims the connect slot and dispatches the handshake off-queue, or no-ops
    /// when already connected/connecting, disarmed, or the root URL is unknown.
    ///
    /// Coalescing a trigger that arrives while a connect is in flight (`connecting
    /// == true`) is safe: that in-flight attempt either succeeds, or fails and
    /// retries via `finishFailedConnect`, so the coalesced request's intent — be
    /// connected — is still satisfied without a lost edge.
    private func connectIfNeeded() {
        let root: URL? = lock.withLock {
            guard connection == nil, !connecting else { return nil }
            guard relayService != nil, let rootURL else { return nil }
            connecting = true
            return rootURL
        }
        guard let root else { return }
        queue.async { [weak self] in self?.connect(rootURL: root) }
    }

    private func connect(rootURL: URL) {
        connectOperation(rootURL) { [weak self] connection in
            guard let self else {
                // The connector went away while the two-hop connect was in
                // flight — unlike a live connector, there's nothing left to
                // notify, but a successfully obtained connection must still be
                // invalidated rather than silently dropped live.
                connection?.invalidate()
                return
            }
            if let connection {
                self.configureAndResume(connection)
            } else {
                self.finishFailedConnect()
            }
        }
    }

    /// Exports the relay, pins the extension, and resumes — storing the
    /// connection before `resume()` so an immediate invalidation reconnects.
    private func configureAndResume(_ connection: NSXPCConnection) {
        // We EXPORT the relay (the extension calls it back) and REMOTE the control
        // interface (we call `ownerDidConnect` to activate the connection). Mirror of
        // the extension's `FileProviderServiceSource` (inverted wiring, #460).
        connection.exportedInterface = NSXPCInterface(with: FileProviderRelay.self)
        connection.remoteObjectInterface = NSXPCInterface(with: FileProviderControl.self)
        // Pin the extension when the direction requires it (host pins the host
        // extension; guest leaves it nil — per-VM vsock auth is tracked by #145).
        if let extensionRequirement {
            connection.setCodeSigningRequirement(extensionRequirement)
        }
        connection.invalidationHandler = { [weak self] in self?.handleConnectionDropped(connection) }
        connection.interruptionHandler = { [weak self] in self?.handleConnectionDropped(connection) }

        // Read the relay and store the connection under ONE lock hold. `stopServing`
        // can clear `relayService` on another thread while this connect is in flight
        // (its completion runs on a framework callback thread); a separate
        // read-then-store would let a just-disabled connector still end up with a
        // live connection exporting the relay. Re-checking here means a concurrent
        // disable reliably drops this connection instead of racing past it.
        let armed: Bool = lock.withLock {
            guard let relay = relayService else { return false }
            connection.exportedObject = relay
            self.connection = connection
            self.connecting = false
            self.connectAttempts = 0
            return true
        }
        guard armed else {
            connection.invalidate()
            finishFailedConnect()
            return
        }
        connection.resume()
        // Activate the connection so the extension's listener accepts it (it delivers
        // shouldAcceptNewConnection only on our first message — see the control doc).
        activate(connection)
        logger.notice("Servicing control connection established")
    }

    /// Sends the `ownerDidConnect` activation handshake on `connection`; a delivery
    /// error means the connection is already dead, so drop it and reconnect.
    private func activate(_ connection: NSXPCConnection) {
        let control =
            connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.handleConnectionDropped(connection)
            } as? FileProviderControl
        control?.ownerDidConnect {}
    }

    /// Settles a failed connect attempt.
    ///
    /// Releases the connect slot, then retries a bounded number of times (the
    /// extension may be mid-relaunch) or gives up so a permanently unreachable
    /// extension can't spin. On giving up, the extension's own bounded
    /// `fetchContents` wait returns `serverUnreachable`; a later doorbell or publish
    /// then starts a fresh burst.
    ///
    /// Also the settle path when a connect completes but the connector was disabled
    /// meanwhile (`relayService == nil`) — the guards below simply schedule no retry.
    private func finishFailedConnect() {
        var attempt = 0
        let retryRoot: URL? = lock.withLock {
            connecting = false
            guard connection == nil, relayService != nil, let rootURL else { return nil }
            connectAttempts += 1
            guard connectAttempts < maxConnectAttempts else {
                connectAttempts = 0
                return nil
            }
            attempt = connectAttempts
            connecting = true  // hold the slot for the scheduled retry
            return rootURL
        }
        guard let retryRoot else { return }
        logger.notice(
            "Servicing connect failed — retry \(attempt, privacy: .public)/\(maxConnectAttempts - 1, privacy: .public) scheduled"
        )
        queue.asyncAfter(deadline: .now() + connectRetryDelay) { [weak self] in
            self?.connect(rootURL: retryRoot)
        }
    }

    /// Clears a dropped connection (only if still current) and reconnects while
    /// armed.
    ///
    /// A relaunched extension also rings the doorbell, so this and the doorbell are
    /// complementary recovery paths.
    private func handleConnectionDropped(_ connection: NSXPCConnection) {
        let shouldReconnect: Bool = lock.withLock {
            guard self.connection === connection else { return false }
            self.connection = nil
            connectAttempts = 0  // a live connection dropped → fresh retry budget
            return relayService != nil && rootURL != nil
        }
        // Invalidate the dropped connection whether or not it was still current.
        // On the invalidation path this is a documented no-op; on the interruption
        // path (extension crash/relaunch, which does NOT auto-invalidate) it breaks
        // the connection↔handler-block retain cycle so the old connection is freed
        // instead of leaking one per relaunch. Done outside the lock — `invalidate`
        // can run handlers synchronously.
        connection.invalidate()
        guard shouldReconnect else { return }
        logger.notice("Servicing connection dropped — reconnecting")
        connectIfNeeded()
    }

    #if DEBUG
    /// Whether the connector currently holds a live control connection.
    var isConnectedForTesting: Bool { lock.withLock { connection != nil } }

    /// Whether a connect handshake is currently in flight.
    var isConnectingForTesting: Bool { lock.withLock { connecting } }

    /// Consecutive failed connect attempts in the current retry burst.
    var connectAttemptsForTesting: Int { lock.withLock { connectAttempts } }

    /// Directly invokes the reconnect-doorbell handler.
    ///
    /// Dispatched onto the connector's private `queue` — the same execution
    /// context the real doorbell always runs on (see `startServing`'s
    /// `DarwinNotificationObserver`).
    ///
    /// The real doorbell relies on `CFNotificationCenter` delivery on a running
    /// main run loop, which the KernovaKit SwiftPM test target does not host (see
    /// `DarwinNotificationTests`) — so tests drive the handler directly instead of
    /// posting a real Darwin notification that would never arrive.
    func triggerReconnectDoorbellForTesting() { queue.sync { handleReconnectDoorbell() } }
    #endif
}
