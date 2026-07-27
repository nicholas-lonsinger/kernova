import FileProvider
import Foundation

// How the domain host connects to the sandboxed extension to serve its relay: both
// directions use the canonical `NSFileProviderServicing` anonymous-XPC pattern, the
// owner as XPC client exporting the relay for the extension to call back at
// `fetchContents`. The extension can't initiate a connection, so the owner connects
// proactively at publish time and reconnects on the Darwin doorbell. Look the service
// up by ITEM IDENTIFIER, never by path: the path-based
// `FileManager.getFileProviderServicesForItem(at:)` needs filesystem access under
// `~/Library/CloudStorage`, which the sandboxed host app does not have (Cocoa 257).

/// Connects the domain host to its File Provider extension so the extension can
/// call the relay back.
public protocol FileProviderRelayTransport: AnyObject, Sendable {
    /// Arms the connector with the relay `service` to export, and starts
    /// listening for the reconnect doorbell. Idempotent — called on each enable.
    func startServing(_ service: FileProviderRelay)

    /// Disarms the connector (clipboard sharing disabled): clears the served
    /// relay, drops any live connection, and stops observing the doorbell so a
    /// call made while disabled can't reach a stale relay.
    func stopServing()

    /// Proactively (re)establishes the control connection to the extension.
    /// Idempotent: a live or in-flight connection short-circuits. Runs the
    /// connect off the caller's thread so it can't block.
    func ensureConnected()
}

// MARK: - Servicing connector

/// Reaches the extension's `NSFileProviderServicing` endpoint, exports the relay,
/// and keeps the control connection warm — reconnecting on the Darwin doorbell or
/// an XPC invalidation.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; the immutable
/// addressing/logging values are set once in `init`.
public final class FileProviderServicingConnector: NSObject,
    FileProviderRelayTransport, @unchecked Sendable
{
    /// Establishes the control connection to the extension.
    ///
    /// Both system calls collapse into one closure because `NSFileProviderService`
    /// is opaque and non-instantiable — a test cannot fabricate one to inject.
    typealias ConnectOperation =
        @Sendable (_ completion: @escaping @Sendable (NSXPCConnection?) -> Void) -> Void

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
    /// Whether `ensureConnected` has ever been called.
    ///
    /// Gates connect attempts so a doorbell arriving before the domain is
    /// registered doesn't spin the retry budget. Deliberately not cleared by
    /// `stopServing`: the domain stays registered across policy off→on cycles, so
    /// a doorbell after a re-enable can reconnect immediately.
    private var connectRequested = false
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
    /// external (re)connect trigger; incremented on each transient failure.
    private var connectAttempts = 0

    /// Upper bound on transient connect retries before giving up.
    ///
    /// Sized so `maxConnectAttempts × connectRetryDelay` spans the extension's own
    /// `FileProviderServiceSource.connectTimeout` — a slow-relaunching extension
    /// must still be caught inside the window the paste is waiting. Both defaults
    /// derive from `FileProviderServicingTiming`, so editing one re-derives the
    /// other rather than silently misaligning.
    private let maxConnectAttempts: Int
    /// Delay between transient connect retries.
    private let connectRetryDelay: DispatchTimeInterval

    private static let defaultMaxConnectAttempts = FileProviderServicingTiming.maxConnectAttempts
    private static let defaultConnectRetryDelay = FileProviderServicingTiming.connectRetryDelay

    /// Creates a connector for one direction from its config.
    public convenience init(config: FileProviderConfig) {
        // Built from `config`'s values, never `self`: `connectOperation` is a stored
        // `let` assigned before the delegated init runs, so no closure here can
        // capture `self`.
        let logger = KernovaLogger(
            subsystem: config.loggerSubsystem, category: "ServicingConnector")
        let serviceName = config.serviceName
        let operation: ConnectOperation = { completion in
            // The domain is built fresh per attempt: `NSFileProviderDomain` itself
            // can't cross this `@Sendable` closure boundary.
            let domain = config.makeDomain()
            guard let manager = NSFileProviderManager(for: domain) else {
                logger.error(
                    "No NSFileProviderManager for domain '\(domain.identifier.rawValue, privacy: .public)'"
                )
                completion(nil)
                return
            }
            manager.getService(named: serviceName, for: .rootContainer) { service, error in
                guard let service else {
                    logger.error(
                        "getService(named: \(serviceName.rawValue, privacy: .public)) failed: \(error?.localizedDescription ?? "no service offered", privacy: .public)"
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
    /// Omitting `logger` builds one from `config`.
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

    /// Proactively (re)establishes the control connection if not already
    /// connected.
    public func ensureConnected() {
        // An explicit (re)connect request restarts the retry budget.
        lock.withLock {
            connectRequested = true
            connectAttempts = 0
        }
        connectIfNeeded()
    }

    // MARK: - Connection lifecycle

    private func handleReconnectDoorbell() {
        logger.notice("Reconnect doorbell received")
        // The doorbell means the extension has no accepted connection and is
        // actively waiting, so reset the retry budget.
        let existing: NSXPCConnection? = lock.withLock {
            connectAttempts = 0
            return self.connection
        }
        if let existing {
            // Re-send the handshake rather than tearing the connection down: on a
            // secretly-dead connection the handshake's error handler drops it and
            // reconnects, and a healthy one whose pulls are mid-flight survives.
            activate(existing)
        } else {
            connectIfNeeded()
        }
    }

    /// Claims the connect slot and dispatches the handshake off-queue, or no-ops
    /// when already connected/connecting, disarmed, or no connect was requested
    /// yet.
    ///
    /// Coalescing a trigger that arrives mid-connect is safe: the in-flight attempt
    /// either succeeds or retries via `finishFailedConnect`, so no edge is lost.
    private func connectIfNeeded() {
        let claimed: Bool = lock.withLock {
            guard connection == nil, !connecting else { return false }
            guard relayService != nil, connectRequested else { return false }
            connecting = true
            return true
        }
        guard claimed else { return }
        queue.async { [weak self] in self?.connect() }
    }

    private func connect() {
        connectOperation { [weak self] connection in
            guard let self else {
                // The connector went away mid-connect: a successfully obtained
                // connection must still be invalidated, not dropped live.
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
        connection.exportedInterface = NSXPCInterface(with: FileProviderRelay.self)
        connection.remoteObjectInterface = NSXPCInterface(with: FileProviderControl.self)
        if let extensionRequirement {
            connection.setCodeSigningRequirement(extensionRequirement)
        }
        connection.invalidationHandler = { [weak self] in self?.handleConnectionDropped(connection) }
        connection.interruptionHandler = { [weak self] in self?.handleConnectionDropped(connection) }

        // Read the relay and store the connection under ONE lock hold. `stopServing`
        // can clear `relayService` on another thread while this connect is in
        // flight, and a separate read-then-store would let a just-disabled
        // connector still end up with a live connection exporting the relay.
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
        // The extension's listener delivers `shouldAcceptNewConnection` only on our
        // first message, so the handshake is what actually gets us accepted.
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
    /// extension can't spin; a later doorbell or publish starts a fresh burst.
    /// Also the settle path when a connect completes but the connector was disabled
    /// meanwhile (`relayService == nil`) — the guards below schedule no retry.
    private func finishFailedConnect() {
        var attempt = 0
        let shouldRetry: Bool = lock.withLock {
            connecting = false
            guard connection == nil, relayService != nil, connectRequested else { return false }
            connectAttempts += 1
            guard connectAttempts < maxConnectAttempts else {
                connectAttempts = 0
                return false
            }
            attempt = connectAttempts
            connecting = true  // hold the slot for the scheduled retry
            return true
        }
        guard shouldRetry else { return }
        logger.notice(
            "Servicing connect failed — retry \(attempt, privacy: .public)/\(maxConnectAttempts - 1, privacy: .public) scheduled"
        )
        queue.asyncAfter(deadline: .now() + connectRetryDelay) { [weak self] in
            self?.connect()
        }
    }

    /// Clears a dropped connection (only if still current) and reconnects while
    /// armed.
    private func handleConnectionDropped(_ connection: NSXPCConnection) {
        let shouldReconnect: Bool = lock.withLock {
            guard self.connection === connection else { return false }
            self.connection = nil
            connectAttempts = 0  // a live connection dropped → fresh retry budget
            return relayService != nil && connectRequested
        }
        // Invalidate whether or not it was still current: on the invalidation path
        // this is a documented no-op, but interruption (extension crash/relaunch)
        // does NOT auto-invalidate, and without this the connection↔handler retain
        // cycle leaks one connection per relaunch. Outside the lock — `invalidate`
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

    /// Directly invokes the reconnect-doorbell handler on the connector's private
    /// `queue` — the same context the real doorbell runs on.
    ///
    /// The real doorbell needs `CFNotificationCenter` delivery on a running main
    /// run loop, which the KernovaKit SwiftPM test target does not host.
    func triggerReconnectDoorbellForTesting() { queue.sync { handleReconnectDoorbell() } }
    #endif
}
