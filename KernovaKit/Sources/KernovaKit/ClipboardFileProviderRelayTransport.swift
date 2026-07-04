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
// from `ClipboardFileProviderConfig`.

/// Connects the domain host to its File Provider extension so the extension can
/// call the relay back.
///
/// Injected into `ClipboardFileProviderDomainHost`; the default is a
/// `ClipboardFileProviderServicingConnector`, and tests inject a no-op.
public protocol ClipboardFileProviderRelayTransport: AnyObject, Sendable {
    /// Arms the connector with the relay `service` to export, and starts
    /// listening for the reconnect doorbell. Idempotent — called on each enable.
    func startServing(_ service: ClipboardFileProviderRelay)

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

/// The single `ClipboardFileProviderRelayTransport` implementation: reaches the
/// extension's `NSFileProviderServicing` endpoint, exports the relay, and keeps
/// the control connection warm (reconnecting on the Darwin doorbell or an XPC
/// invalidation).
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; the immutable
/// addressing/logging values are set once in `init`. The exported relay carries
/// no bytes — only `(generation, repIndex)` crosses, and the reply is a staged
/// app-group path.
public final class ClipboardFileProviderServicingConnector: NSObject,
    ClipboardFileProviderRelayTransport, @unchecked Sendable
{
    private let serviceName: NSFileProviderServiceName
    private let reconnectNotificationName: String
    private let extensionRequirement: String?
    private let logger: KernovaLogger
    /// Serializes the connect handshake and the doorbell handler off the main
    /// queue (the connect must never block the owner's main actor).
    private let queue = DispatchQueue(label: "app.kernova.fileprovider.connector")

    private let lock = NSLock()
    /// The relay object exported to the extension; `nil` while disabled.
    private var relayService: ClipboardFileProviderRelay?
    /// The domain root URL to connect through, cached from `ensureConnected`.
    private var rootURL: URL?
    /// The live control connection, or `nil` when not connected.
    private var connection: NSXPCConnection?
    /// `true` while a connect handshake is in flight (coalesces concurrent
    /// attempts).
    private var connecting = false
    /// Observes the reconnect doorbell while armed.
    private var reconnectObserver: DarwinNotificationObserver?

    /// Creates a connector for one direction from its config.
    public init(config: ClipboardFileProviderConfig) {
        self.serviceName = config.serviceName
        self.reconnectNotificationName = config.reconnectNotificationName
        self.extensionRequirement = config.extensionCodeSigningRequirement
        self.logger = KernovaLogger(
            subsystem: config.loggerSubsystem, category: "ServicingConnector")
        super.init()
    }

    // MARK: - ClipboardFileProviderRelayTransport

    /// Arms the connector with the relay to export and starts observing the
    /// reconnect doorbell.
    public func startServing(_ service: ClipboardFileProviderRelay) {
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
        lock.withLock { self.rootURL = rootURL }
        connectIfNeeded()
    }

    // MARK: - Connection lifecycle

    private func handleReconnectDoorbell() {
        logger.notice("Reconnect doorbell received — (re)establishing servicing connection")
        connectIfNeeded()
    }

    /// Claims the connect slot and dispatches the handshake off-queue, or no-ops
    /// when already connected/connecting, disarmed, or the root URL is unknown.
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
        // Root is a real directory (never a dataless file placeholder) so this
        // can't trigger reentrant materialization → deadlock (P1b, #460).
        FileManager.default.getFileProviderServicesForItem(at: rootURL) { [weak self] services, error in
            guard let self else { return }
            if let error {
                self.logger.error(
                    "getFileProviderServicesForItem failed: \(error.localizedDescription, privacy: .public)"
                )
                self.clearConnecting()
                return
            }
            guard let service = services?[self.serviceName] else {
                self.logger.error(
                    "Servicing endpoint '\(self.serviceName.rawValue, privacy: .public)' not offered by the extension"
                )
                self.clearConnecting()
                return
            }
            service.getFileProviderConnection { connection, error in
                guard let connection else {
                    self.logger.error(
                        "getFileProviderConnection failed: \(error?.localizedDescription ?? "nil connection", privacy: .public)"
                    )
                    self.clearConnecting()
                    return
                }
                self.configureAndResume(connection)
            }
        }
    }

    /// Exports the relay, pins the extension, and resumes — storing the
    /// connection before `resume()` so an immediate invalidation reconnects.
    private func configureAndResume(_ connection: NSXPCConnection) {
        let relay: ClipboardFileProviderRelay? = lock.withLock { self.relayService }
        guard let relay else {
            // Disabled between the connect start and now — drop it.
            connection.invalidate()
            clearConnecting()
            return
        }
        // The owner only EXPORTS the relay — it never calls the extension — so no
        // `remoteObjectInterface` here (inverted wiring, #460).
        connection.exportedInterface = NSXPCInterface(with: ClipboardFileProviderRelay.self)
        connection.exportedObject = relay
        // Pin the extension when the direction requires it (host pins the host
        // extension; guest leaves it nil — per-VM vsock auth is tracked by #145).
        if let extensionRequirement {
            connection.setCodeSigningRequirement(extensionRequirement)
        }
        connection.invalidationHandler = { [weak self] in self?.handleConnectionDropped(connection) }
        connection.interruptionHandler = { [weak self] in self?.handleConnectionDropped(connection) }
        lock.withLock {
            self.connection = connection
            self.connecting = false
        }
        connection.resume()
        logger.notice("Servicing control connection established")
    }

    private func clearConnecting() {
        lock.withLock { self.connecting = false }
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
            return relayService != nil && rootURL != nil
        }
        guard shouldReconnect else { return }
        logger.notice("Servicing connection dropped — reconnecting")
        connectIfNeeded()
    }
}
