import FileProvider
import Foundation

// How the domain host vends its relay to the sandboxed extension (issues #376
// guest / #424 host).
//
// Both directions vend the relay on a team-prefixed Mach service the sandboxed
// extension looks up (its name is app-group-prefixed, so the extension is
// allowed to reach it). The guest agent and the main app are both
// launchd-managed LaunchAgents whose plist `MachServices` key registers the
// name, so each can host an `NSXPCListener(machServiceName:)` directly.
//
//   • The guest agent uses `MachServiceRelayTransport`: the listener is created
//     on first enable and persists; the served relay is set on enable and
//     cleared on disable (`startServing` / `stopServing`).
//   • The main app uses `HostRelayListener`: an always-on listener (it also
//     serves the launcher's GUI-summon verb, which must work even when no VM
//     has clipboard sharing on) into which the clipboard relay service is
//     registered while sharing is enabled and cleared when it is disabled.
//
// The domain host owns the relay *service* (built from its pull provider) and
// hands it to whichever transport it was constructed with, keeping its
// enable/disable lifecycle identical across directions.

/// Vends a `ClipboardFileProviderRelay` to the File Provider extension.
///
/// Injected into `ClipboardFileProviderDomainHost`; the guest creates its Mach
/// listener on enable, the host registers its relay service into the agent's
/// always-on listener.
public protocol ClipboardFileProviderRelayTransport: AnyObject, Sendable {
    /// Begins vending `service`. Idempotent — called on each enable; the
    /// underlying listener is created once and the served relay is (re)set.
    func startServing(_ service: ClipboardFileProviderRelay)

    /// Stops routing to the served relay (clipboard sharing disabled).
    ///
    /// Clears the served relay so a call made while disabled fails cleanly —
    /// `serverUnreachable` on the host, a refused connection on the guest — rather
    /// than routing to a relay whose offer has been cleared. The Mach listener
    /// itself is kept for the process lifetime (the host multiplexes GUI-summon on
    /// it, and re-vending a launchd Mach name is avoided), so a later enable
    /// re-arms via `startServing`.
    func stopServing()
}

// MARK: - Guest: direct Mach-service listener

/// Vends the relay on a team-prefixed Mach service the guest agent's LaunchAgent
/// plist registers (`MachServices`), which the sandboxed guest extension looks up.
///
/// `@unchecked Sendable`: `listener` is created once on first `startServing` (on
/// the owner's queue) and read by the XPC delegate thereafter; the served
/// `service` is read/written only under `lock`, so `stopServing` on the owner's
/// queue and the delegate's connection-accept on the XPC queue can't race.
public final class MachServiceRelayTransport: NSObject, NSXPCListenerDelegate,
    ClipboardFileProviderRelayTransport, @unchecked Sendable
{
    private let machServiceName: String
    private let logger: KernovaLogger
    private let lock = NSLock()
    private var listener: NSXPCListener?
    private var service: ClipboardFileProviderRelay?

    /// Vends on `machServiceName`, logging under `loggerSubsystem`.
    public init(machServiceName: String, loggerSubsystem: String) {
        self.machServiceName = machServiceName
        self.logger = KernovaLogger(subsystem: loggerSubsystem, category: "RelayTransport")
        super.init()
    }

    /// (Re)sets the served relay and starts the Mach listener on first call.
    ///
    /// The served relay is updated on every enable; the listener is created once
    /// and then persists for a later enable after a `stopServing`.
    public func startServing(_ service: ClipboardFileProviderRelay) {
        lock.withLock { self.service = service }
        guard listener == nil else { return }
        let listener = NSXPCListener(machServiceName: machServiceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
        logger.notice(
            "Relay Mach listener started (\(self.machServiceName, privacy: .public))")
    }

    /// Clears the served relay so connections opened while clipboard sharing is
    /// disabled are refused; the listener persists for a later `startServing`.
    public func stopServing() {
        lock.withLock { self.service = nil }
        logger.notice("Relay service cleared (clipboard disabled); Mach listener kept")
    }

    /// Exports the relay service to a connecting extension, or refuses the
    /// connection when no relay is currently served (clipboard disabled).
    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // RATIONALE: the guest leg is not yet peer-validated (per-VM vsock auth is
        // tracked by #145); the team-prefixed Mach name + app-group lookup gate
        // already restrict who can reach it. The host leg IS validated via
        // `setCodeSigningRequirement` (see `HostRelayListener`).
        guard let service = lock.withLock({ self.service }) else {
            logger.debug("Refused File Provider XPC connection — no relay served (disabled)")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: ClipboardFileProviderRelay.self)
        newConnection.exportedObject = service
        newConnection.resume()
        logger.debug("Accepted File Provider XPC connection")
        return true
    }
}

// MARK: - Host: always-on `…xpc` listener (clipboard + GUI summon)

/// The object the host agent exports on its `…xpc` Mach service.
///
/// Multiplexes the sandboxed extension's `fetchFile` (forwarded to the
/// registered clipboard relay, or `serverUnreachable` when no VM has sharing on)
/// and the launcher's `summon` (forwarded to the injected closure).
///
/// `@unchecked Sendable`: `relayProvider` is read/written only under `lock`;
/// `onSummon`/`logger` are immutable.
final class HostRelayService: NSObject, KernovaHostRelay, @unchecked Sendable {
    private let lock = NSLock()
    private var relayProvider: ClipboardFileProviderRelay?
    private let onSummon: @Sendable ([String]) -> Void
    private let logger: KernovaLogger

    init(
        loggerSubsystem: String,
        onSummon: @escaping @Sendable ([String]) -> Void
    ) {
        self.onSummon = onSummon
        self.logger = KernovaLogger(subsystem: loggerSubsystem, category: "HostRelayService")
        super.init()
    }

    /// Registers (or clears) the clipboard relay that backs `fetchFile`.
    func setRelayProvider(_ provider: ClipboardFileProviderRelay?) {
        lock.withLock { self.relayProvider = provider }
    }

    /// Forwards to the registered clipboard relay, or replies `serverUnreachable`
    /// when none is registered (no VM has clipboard sharing on).
    ///
    /// The provider is an in-process object, so this is a direct call — unlike
    /// the former cross-process broker there is no connection to drop mid-pull.
    func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        let provider = lock.withLock { self.relayProvider }
        guard let provider else {
            logger.error("fetchFile with no registered relay provider")
            reply(
                nil,
                NSError(
                    domain: NSFileProviderErrorDomain,
                    code: NSFileProviderError.serverUnreachable.rawValue))
            return
        }
        provider.fetchFile(generation: generation, repIndex: repIndex, reply: reply)
    }

    /// Imports any forwarded `.kernova` bundle paths and brings the resident
    /// agent's GUI forward, then confirms delivery so the launcher can exit.
    ///
    /// The injected closure does both (import first, then summon) on the main
    /// actor so the imported VM is selected before the window is shown. An
    /// empty `vmPaths` is a plain summon.
    func summon(vmPaths: [String], reply: @escaping @Sendable () -> Void) {
        logger.notice("Received summon request (\(vmPaths.count, privacy: .public) VM path(s))")
        onSummon(vmPaths)
        reply()
    }
}

/// Hosts the main app's always-on `…xpc` Mach listener.
///
/// Created and `start()`ed once by the agent at launch (independent of clipboard
/// policy, so GUI-summon works at login). As a `ClipboardFileProviderRelayTransport`
/// it registers the clipboard relay service as the `fetchFile` backing on enable.
///
/// `@unchecked Sendable`: `listener` is set once on `start()` (on the owner's
/// queue) and read by the XPC delegate thereafter; `service`/`logger` are
/// immutable, and the service guards its own mutable state.
public final class HostRelayListener: NSObject, NSXPCListenerDelegate,
    ClipboardFileProviderRelayTransport, @unchecked Sendable
{
    private let machServiceName: String
    private let inboundRequirement: String
    private let logger: KernovaLogger
    private let service: HostRelayService
    private var listener: NSXPCListener?

    /// Vends on `machServiceName`, validating inbound peers against
    /// `inboundCodeSigningRequirement`, and forwards `summon` to the injected
    /// closure (invoked off-main on the XPC queue — the closure must hop to the
    /// main actor itself).
    public init(
        machServiceName: String,
        inboundCodeSigningRequirement: String,
        loggerSubsystem: String,
        onSummon: @escaping @Sendable ([String]) -> Void
    ) {
        self.machServiceName = machServiceName
        self.inboundRequirement = inboundCodeSigningRequirement
        self.logger = KernovaLogger(subsystem: loggerSubsystem, category: "HostRelayListener")
        self.service = HostRelayService(loggerSubsystem: loggerSubsystem, onSummon: onSummon)
        super.init()
    }

    /// Starts the Mach listener on first call; subsequent calls are no-ops.
    ///
    /// Always-on for the agent's lifetime, so the launcher can summon the GUI
    /// even before any VM enables clipboard sharing.
    public func start() {
        guard listener == nil else { return }
        let listener = NSXPCListener(machServiceName: machServiceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
        logger.notice(
            "Host relay Mach listener started (\(self.machServiceName, privacy: .public))")
    }

    /// Registers the clipboard relay service as the `fetchFile` backing.
    ///
    /// `ClipboardFileProviderRelayTransport` conformance, called by the domain
    /// host on enable. The listener itself is already up from `start()`.
    public func startServing(_ service: ClipboardFileProviderRelay) {
        self.service.setRelayProvider(service)
        logger.notice("Clipboard relay provider registered with host listener")
    }

    /// Clears the `fetchFile` backing when clipboard sharing is disabled.
    ///
    /// `ClipboardFileProviderRelayTransport` conformance, called by the domain
    /// host on disable. The always-on listener stays up (it also serves the
    /// launcher's GUI-summon), so `fetchFile` now replies `serverUnreachable`
    /// until the next `startServing`.
    public func stopServing() {
        service.setRelayProvider(nil)
        logger.notice("Clipboard relay provider cleared from host listener")
    }

    #if DEBUG
    /// The multiplexed relay service, exposed for `HostRelayServiceTests` to assert
    /// that `startServing`/`stopServing` toggle the `fetchFile` backing without
    /// standing up the live Mach listener (`start()` is never called in the test).
    var relayServiceForTesting: HostRelayService { service }
    #endif

    /// Validates the peer (main app launcher or host extension) and exports the
    /// multiplexed relay.
    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Framework-enforced peer validation: a peer that isn't the Kernova-team
        // main app or host File Provider extension has its calls invalidated.
        // Non-throwing — a malformed requirement *string* raises, which would be a
        // compile-time-constant bug caught in dev.
        newConnection.setCodeSigningRequirement(inboundRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: KernovaHostRelay.self)
        newConnection.exportedObject = service
        newConnection.resume()
        logger.debug("Accepted host relay XPC connection")
        return true
    }
}
