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
// Usage: launched by launchd (KeepAlive); takes no arguments.

private let logger = Logger(subsystem: "app.kernova.clipboard.relay", category: "Broker")

// MARK: - Broker service

/// The object exported on the broker's Mach service.
///
/// The main app calls `registerProvider()` on its outbound connection to
/// nominate itself as the backing relay; the extension calls `fetchFile`, which
/// the broker forwards to that registered relay.
///
/// `@unchecked Sendable`: `provider` is the only mutable state and is read and
/// written solely under `lock`.
final class BrokerService: NSObject, ClipboardFileProviderBroker, @unchecked Sendable {
    private let lock = NSLock()
    private var provider: ClipboardFileProviderRelay?

    /// Captures the calling (main-app) connection's `remoteObjectProxy` as the
    /// backing relay and clears it when that connection invalidates.
    func registerProvider() {
        guard let connection = NSXPCConnection.current() else {
            logger.error("registerProvider called outside an XPC connection")
            return
        }
        let proxy = connection.remoteObjectProxy as? ClipboardFileProviderRelay
        lock.lock()
        provider = proxy
        lock.unlock()
        // Clear the provider when the main app goes away, so a later fetchFile
        // fails cleanly instead of forwarding to a dead proxy.
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.provider = nil
            self.lock.unlock()
            logger.notice("Provider connection invalidated; cleared")
        }
        logger.notice("Main app registered as relay provider")
    }

    /// Forwards `(generation, repIndex)` to the registered main-app relay, or
    /// replies `serverUnreachable` when no provider is registered.
    func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        lock.lock()
        let provider = self.provider
        lock.unlock()
        guard let provider else {
            logger.error("fetchFile with no registered provider")
            reply(
                nil,
                NSError(
                    domain: NSFileProviderErrorDomain,
                    code: NSFileProviderError.serverUnreachable.rawValue))
            return
        }
        logger.debug(
            "Forwarding fetchFile (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public))"
        )
        provider.fetchFile(generation: generation, repIndex: repIndex, reply: reply)
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

// launchd owns the lifecycle (KeepAlive); `resume()` returns immediately, so keep
// the process alive to service connections.
RunLoop.main.run()
