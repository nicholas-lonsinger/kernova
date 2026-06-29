import Foundation

// How the domain host vends its relay to the sandboxed extension (issues #376
// guest / #424 host).
//
// The guest agent is a LaunchAgent, so it vends the relay directly on a
// team-prefixed Mach service (`MachServiceRelayTransport`). The main app is
// neither sandboxed nor launchd-managed and can't register a Mach service, so it
// connects out to an SMAppService broker and registers itself as the backing
// relay (`BrokerRelayTransport`). The domain host owns the relay *service*
// (built from its pull provider) and hands it to whichever transport it was
// constructed with, keeping its enable/disable lifecycle identical across
// directions.

/// Vends a `ClipboardFileProviderRelay` to the File Provider extension.
///
/// Injected into `ClipboardFileProviderDomainHost` so the guest uses a Mach
/// listener and the host uses the broker.
public protocol ClipboardFileProviderRelayTransport: AnyObject, Sendable {
    /// Begins vending `service`. Idempotent — called on each enable, vends once.
    func startServing(_ service: ClipboardFileProviderRelay)
}

// MARK: - Guest: direct Mach-service listener

/// Vends the relay on a team-prefixed Mach service the guest agent's LaunchAgent
/// plist registers (`MachServices`), which the sandboxed guest extension looks up.
///
/// `@unchecked Sendable`: `listener`/`service` are set once on first
/// `startServing` (on the owner's queue) and read by the XPC delegate thereafter.
public final class MachServiceRelayTransport: NSObject, NSXPCListenerDelegate,
    ClipboardFileProviderRelayTransport, @unchecked Sendable
{
    private let machServiceName: String
    private let logger: KernovaLogger
    private var listener: NSXPCListener?
    private var service: ClipboardFileProviderRelay?

    /// Vends on `machServiceName`, logging under `loggerSubsystem`.
    public init(machServiceName: String, loggerSubsystem: String) {
        self.machServiceName = machServiceName
        self.logger = KernovaLogger(subsystem: loggerSubsystem, category: "RelayTransport")
        super.init()
    }

    /// Starts the Mach listener on first call; subsequent calls are no-ops.
    public func startServing(_ service: ClipboardFileProviderRelay) {
        guard listener == nil else { return }
        self.service = service
        let listener = NSXPCListener(machServiceName: machServiceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
        logger.notice(
            "Relay Mach listener started (\(self.machServiceName, privacy: .public))")
    }

    /// Exports the relay service to a connecting extension.
    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // RATIONALE: the guest leg is not yet peer-validated (per-VM vsock auth is
        // tracked by #145); the team-prefixed Mach name + app-group lookup gate
        // already restrict who can reach it. The host legs ARE validated via
        // `setCodeSigningRequirement` (see `BrokerRelayTransport` and the broker).
        newConnection.exportedInterface = NSXPCInterface(with: ClipboardFileProviderRelay.self)
        newConnection.exportedObject = service
        newConnection.resume()
        logger.debug("Accepted File Provider XPC connection")
        return true
    }
}

// MARK: - Host: SMAppService broker client

/// Connects out to the SMAppService broker and registers the main app's relay as
/// the broker's backing provider (the main app can't vend a Mach service itself).
///
/// `@unchecked Sendable`: `connection`/`service` are set once on first
/// `startServing` (on the owner's queue) and read by the invalidation handler.
public final class BrokerRelayTransport: ClipboardFileProviderRelayTransport, @unchecked Sendable {
    private let logger: KernovaLogger
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var service: ClipboardFileProviderRelay?

    /// Logs under `loggerSubsystem`.
    ///
    /// The broker LaunchAgent must already be registered (the owner calls
    /// `SMAppService` before enabling).
    public init(loggerSubsystem: String) {
        self.logger = KernovaLogger(subsystem: loggerSubsystem, category: "RelayTransport")
    }

    /// Connects to the broker and registers the relay on first call; subsequent
    /// calls are no-ops until the connection invalidates.
    public func startServing(_ service: ClipboardFileProviderRelay) {
        lock.lock()
        defer { lock.unlock() }
        guard connection == nil else { return }
        self.service = service
        connectAndRegisterLocked(service)
    }

    /// Caller holds `lock`.
    private func connectAndRegisterLocked(_ service: ClipboardFileProviderRelay) {
        let connection = NSXPCConnection(
            machServiceName: ClipboardFileProviderBrokerIdentity.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ClipboardFileProviderBroker.self)
        // The broker calls back into this relay to fetch bytes.
        connection.exportedInterface = NSXPCInterface(with: ClipboardFileProviderRelay.self)
        connection.exportedObject = service
        // Framework-enforced peer validation: only the genuine Kernova broker.
        // Non-throwing — arms the check so an impostor broker has this
        // connection's calls invalidated.
        connection.setCodeSigningRequirement(
            ClipboardFileProviderBrokerIdentity.brokerRequirement)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.connection = nil
            self.lock.unlock()
            self.logger.notice("Broker connection invalidated; will re-register on next enable")
        }
        connection.resume()
        self.connection = connection
        (connection.remoteObjectProxy as? ClipboardFileProviderBroker)?.registerProvider()
        logger.notice(
            "Registered relay with broker (\(ClipboardFileProviderBrokerIdentity.machServiceName, privacy: .public))"
        )
    }
}
