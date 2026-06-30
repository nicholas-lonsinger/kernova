import FileProvider
import Foundation
import KernovaKit
import os

// KernovaClipboardRelayAgent
//
// A launchd-managed XPC broker for the host "Copy to Mac" File Provider relay
// (#424 Phase 2b). The main Kernova app owns the vsock clipboard connection but,
// being neither sandboxed nor launchd-managed, cannot register a Mach service —
// the Phase-0 spike proved launchd refuses `NSXPCListener(machServiceName:)
// .resume()` for it. So this tiny agent, registered at runtime via
// `SMAppService.agent`, vends the app-group-prefixed Mach service the sandboxed
// File Provider extension looks up and forwards each byte-pull to the main app
// over the connection the app opens to register itself:
//
//   extension --fetchFile--> broker --(forwards on the app's connection)--> main app
//
// No bytes cross the broker — only `(generation, repIndex)` in and a staged
// app-group path back; the payload rides the shared app-group container, exactly
// as in the guest path. Both peers (the main app and the host extension) are
// validated via `NSXPCConnection.setCodeSigningRequirement` before the broker
// serves them.
//
// Usage: demand-launched by launchd on the first connection to its Mach service;
// takes no arguments. The plist declares no KeepAlive — the main app's persistent
// connection keeps this process alive while clipboard sharing is enabled, and the
// app re-registers itself (BrokerRelayTransport's interruptionHandler) if launchd
// relaunches this process.

private let logger = Logger(subsystem: "app.kernova.clipboard.relay", category: "Broker")

// MARK: - Broker service

/// The object exported on the broker's Mach service.
///
/// The main app calls `registerProvider()` on its outbound connection to
/// nominate itself as the backing relay; the extension calls `fetchFile`, which
/// the broker forwards to that registered relay.
///
/// `@unchecked Sendable`: `providerConnection` is the only mutable state and is
/// read and written solely under `lock`.
final class BrokerService: NSObject, ClipboardFileProviderBroker, @unchecked Sendable {
    private let lock = NSLock()
    /// The main app's connection — kept (rather than a bare `remoteObjectProxy`) so
    /// each `fetchFile` can build a per-call error-handling proxy.
    ///
    /// A plain proxy silently drops the reply block if the app disconnects
    /// mid-pull, which would hang the extension's deadline-less `fetchContents`
    /// wait forever.
    private var providerConnection: NSXPCConnection?

    /// Captures the calling (main-app) connection as the backing relay and clears
    /// it when that connection invalidates.
    func registerProvider() {
        guard let connection = NSXPCConnection.current() else {
            logger.error("registerProvider called outside an XPC connection")
            return
        }
        lock.lock()
        providerConnection = connection
        lock.unlock()
        // Clear the provider when the main app goes away, so a later fetchFile
        // fails cleanly instead of forwarding to a dead connection.
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // Only clear if a newer registration hasn't already replaced it.
            if self.providerConnection === connection { self.providerConnection = nil }
            self.lock.unlock()
            logger.notice("Provider connection invalidated; cleared")
        }
        logger.notice("Main app registered as relay provider")
    }

    /// Forwards `(generation, repIndex)` to the registered main-app relay, or
    /// replies `serverUnreachable` when no provider is registered or the main app
    /// disconnects mid-pull.
    func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        lock.lock()
        let connection = providerConnection
        lock.unlock()
        guard let connection else {
            logger.error("fetchFile with no registered provider")
            reply(nil, Self.serverUnreachable)
            return
        }
        // `remoteObjectProxyWithErrorHandler`, not a plain proxy: if the main-app
        // connection drops after we forward but before it replies, a plain proxy
        // would silently drop the reply and the sandboxed extension's deadline-less
        // `fetchContents` wait would hang forever. The error handler turns that into
        // a clean serverUnreachable. XPC invokes exactly one of the forwarded reply
        // or this handler, so `reply` is never called twice.
        let proxy =
            connection.remoteObjectProxyWithErrorHandler { error in
                logger.error(
                    "Provider fetchFile failed: \(error.localizedDescription, privacy: .public)")
                reply(nil, Self.serverUnreachable)
            } as? ClipboardFileProviderRelay
        guard let proxy else {
            reply(nil, Self.serverUnreachable)
            return
        }
        logger.debug(
            "Forwarding fetchFile (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public))"
        )
        proxy.fetchFile(generation: generation, repIndex: repIndex, reply: reply)
    }

    /// A fresh `serverUnreachable` error for the extension to surface as a failed
    /// (rather than hung) materialization.
    private static var serverUnreachable: NSError {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: NSFileProviderError.serverUnreachable.rawValue)
    }
}

// MARK: - Listener

/// Accepts connections from the main app and the host extension, validates each
/// peer, and exports the shared `BrokerService`.
///
/// `@unchecked Sendable`: `service` is an immutable `let`.
final class BrokerListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service = BrokerService()

    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Framework-enforced peer validation: arms the connection so a peer that
        // isn't the Kernova-team main app or host File Provider extension has its
        // calls invalidated. (Non-throwing — a malformed requirement *string*
        // raises, which would be a compile-time-constant bug caught in dev.)
        newConnection.setCodeSigningRequirement(
            ClipboardFileProviderBrokerIdentity.clientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: ClipboardFileProviderBroker.self)
        newConnection.exportedObject = service
        // The main app's connection carries a relay back-channel the broker calls
        // on fetchFile; the extension never exports one (it only calls in).
        newConnection.remoteObjectInterface = NSXPCInterface(with: ClipboardFileProviderRelay.self)
        newConnection.resume()
        logger.debug("Accepted broker XPC connection")
        return true
    }
}

// MARK: - Entry point

let delegate = BrokerListenerDelegate()
let listener = NSXPCListener(machServiceName: ClipboardFileProviderBrokerIdentity.machServiceName)
listener.delegate = delegate
listener.resume()
logger.notice(
    "Clipboard relay broker listening on \(ClipboardFileProviderBrokerIdentity.machServiceName, privacy: .public)"
)

// launchd owns the lifecycle (demand-launched; no KeepAlive — the main app's
// connection keeps this process alive while clipboard sharing is enabled).
// `resume()` returns immediately, so keep the process alive to service connections.
RunLoop.main.run()
