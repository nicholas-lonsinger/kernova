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
// live owner connection it rings the Darwin doorbell and blocks (bounded) until
// the owner connects; the timeout returns `serverUnreachable` so Finder is never
// blocked indefinitely when the owner isn't running or the domain is disabled.

/// One long-lived anonymous-XPC service source for a File Provider extension.
///
/// `@unchecked Sendable`: the accepted connection and the wait state are guarded
/// by `condition`; `config`/`logger`/`listener` are immutable after `init`.
final class ClipboardFileProviderServiceSource: NSObject, NSFileProviderServiceSource,
    NSXPCListenerDelegate, @unchecked Sendable
{
    /// Bounded wait for the owner to connect after the doorbell is rung, kept
    /// well under Finder's ~60 s paste deadline so a missing owner fails cleanly.
    private static let connectTimeout: TimeInterval = 30

    private let config: ClipboardFileProviderConfig
    private let logger: Logger
    private let listener: NSXPCListener
    /// Guards `acceptedConnection` and wakes the bounded wait in `fetchStagedFile`.
    private let condition = NSCondition()
    private var acceptedConnection: NSXPCConnection?

    init(config: ClipboardFileProviderConfig, logger: Logger) {
        self.config = config
        self.logger = logger
        self.listener = NSXPCListener.anonymous()
        super.init()
        listener.delegate = self
        listener.resume()
    }

    // MARK: - NSFileProviderServiceSource

    var serviceName: NSFileProviderServiceName { config.serviceName }

    /// The clipboard domain is read-only and single-purpose, so it has nothing
    /// to restrict — the owner code-signing pin (below) is the real gate.
    var isRestricted: Bool { false }

    /// Returns the single long-lived anonymous endpoint.
    ///
    /// Reused on every call — minting a fresh listener per connect would dangle
    /// prior connections.
    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        listener.endpoint
    }

    // MARK: - NSXPCListenerDelegate

    /// Accepts the owner's connection, pins it, and retains it so `fetchContents`
    /// (a different thread) can call back over it.
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // The owner EXPORTS the relay; we call it back — so this is the *remote*
        // interface from our side.
        newConnection.remoteObjectInterface = NSXPCInterface(with: ClipboardFileProviderRelay.self)
        // Pin the owner when the direction requires it (the host pins the main
        // app; the guest leaves it nil — see the config doc and #145). Non-throwing:
        // arms a framework-enforced check, so an impostor owner's calls invalidate.
        if let requirement = config.ownerCodeSigningRequirement {
            newConnection.setCodeSigningRequirement(requirement)
        }
        newConnection.invalidationHandler = { [weak self] in self?.clearConnection(newConnection) }
        newConnection.interruptionHandler = { [weak self] in self?.clearConnection(newConnection) }
        newConnection.resume()

        condition.lock()
        acceptedConnection = newConnection
        // `broadcast`, not `signal`: several `fetchContents` threads can be blocked
        // in `waitForConnection` at once (e.g. the eager copy-time read racing a
        // real paste), and the owner establishes only ONE connection — so a single
        // `signal` would wake just one waiter and strand the rest until their
        // timeout. Wake them all; every one can use the shared connection.
        condition.broadcast()
        condition.unlock()
        logger.debug("Accepted owner servicing connection")
        return true
    }

    /// Clears the retained connection only if it is still the current one (a
    /// newer connection may already have replaced it).
    private func clearConnection(_ connection: NSXPCConnection) {
        condition.lock()
        if acceptedConnection === connection { acceptedConnection = nil }
        condition.unlock()
    }

    // MARK: - Byte pull (called from the extension's fetchContents)

    /// Pulls `(generation, repIndex)` through the owner and returns the staged
    /// file path, or an `NSFileProviderError` on failure.
    ///
    /// Blocks the calling (fetchContents) thread: the File Provider read path has
    /// no per-call deadline, so waiting on the owner is safe. Rings the reconnect
    /// doorbell and waits (bounded) when no owner connection is live.
    func fetchStagedFile(generation: UInt64, repIndex: Int) -> Result<String, NSError> {
        guard let connection = waitForConnection() else {
            return .failure(Self.serverUnreachable)
        }

        final class Outcome: @unchecked Sendable {
            var path: String?
            var error: NSError?
        }
        let outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)

        let proxy =
            connection.remoteObjectProxyWithErrorHandler { error in
                outcome.error = error as NSError
                semaphore.signal()
            } as? ClipboardFileProviderRelay
        guard let proxy else { return .failure(Self.serverUnreachable) }

        proxy.fetchFile(generation: generation, repIndex: repIndex) { path, error in
            outcome.path = path
            outcome.error = error
            semaphore.signal()
        }
        semaphore.wait()

        if let path = outcome.path { return .success(path) }
        return .failure(outcome.error ?? Self.serverUnreachable)
    }

    /// Returns a live owner connection, ringing the doorbell and waiting (bounded)
    /// when none exists. `nil` on timeout (owner not running / domain disabled).
    private func waitForConnection() -> NSXPCConnection? {
        condition.lock()
        if let existing = acceptedConnection {
            condition.unlock()
            return existing
        }
        condition.unlock()

        logger.notice("No live owner connection — posting reconnect doorbell")
        DarwinNotification.post(config.reconnectNotificationName)

        let deadline = Date().addingTimeInterval(Self.connectTimeout)
        condition.lock()
        while acceptedConnection == nil {
            // `wait(until:)` returns false on timeout; loop guards spurious wakeups.
            if !condition.wait(until: deadline) { break }
        }
        let connection = acceptedConnection
        condition.unlock()

        if connection == nil {
            logger.error("Timed out waiting for owner connection after doorbell")
        }
        return connection
    }

    private static let serverUnreachable = NSError(
        domain: NSFileProviderErrorDomain, code: NSFileProviderError.serverUnreachable.rawValue)
}
