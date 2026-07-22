import FileProvider
import Foundation

// The owner-side XPC relay object for the clipboard File Provider transport
// (issues #376 guest / #424 host, servicing wiring #460).
//
// Split out of `FileProviderDomainHost.swift`, which owns domain registration,
// the offer manifest, and availability. This file owns the other half of the
// owner side: the object the domain host exports over the servicing connection
// so the sandboxed extension can call back at `fetchContents` — the extension
// can't open vsock, so the owning process pulls for it and replies with a
// staged *path*, never bytes.

// MARK: - Relay service

/// The XPC-exported relay object.
///
/// Pulls a file rep through the clipboard owner and replies with the staged-file
/// path, never the bytes.
public final class FileProviderRelayService: NSObject, FileProviderRelay {
    private let logger: KernovaLogger
    private let pullProvider: FileProviderPullProvider
    /// Runs each `fetchFile` pull, and each `cancelFetch` signal, off the XPC
    /// delivery queue.
    ///
    /// `NSXPCConnection` delivers every incoming exported-object call — including
    /// `cancelFetch` — on one private *serial* queue per connection (WWDC 2012
    /// session 241), so blocking that queue for the whole vsock pull (as `fetchFile`
    /// used to) would starve any `cancelFetch` for the very fetch it's trying to
    /// abort — and `cancelFetch` itself can block on a stalled peer's vsock write,
    /// so it needs the same treatment. Dispatching here frees the delivery queue
    /// immediately; `.concurrent` also lets independent multi-file pulls actually
    /// run in parallel, which the receiver/coordinator already support.
    private let pullQueue = DispatchQueue(
        label: "app.kernova.fileprovider.relay.pull", attributes: .concurrent)

    /// Creates the relay service, logging under `loggerSubsystem`.
    public init(pullProvider: FileProviderPullProvider, loggerSubsystem: String) {
        self.logger = KernovaLogger(subsystem: loggerSubsystem, category: "FileProviderRelay")
        self.pullProvider = pullProvider
        super.init()
    }

    /// Pulls `(generation, repIndex)` through the owner and replies with the
    /// staged path, or an `NSFileProviderError` on failure.
    public func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        logger.debug(
            "Relay fetchFile (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public))")
        // Capture the calling connection SYNCHRONOUSLY — `NSXPCConnection.current()`
        // is valid only during this incoming invocation, before we hop to
        // `pullQueue`. The pusher then drives determinate progress back to the
        // extension for the pull's duration (#426). `nil` outside XPC (unit tests
        // call `fetchFile` directly) → no pushes, a no-op.
        let pusher = NSXPCConnection.current().map {
            FetchProgressPusher(
                connection: $0, generation: generation, repIndex: repIndex, logger: logger)
        }
        // Off the XPC delivery queue: the File Provider read path has no 60s
        // deadline so a long block is safe, but it must not be *this* queue — see
        // `pullQueue`'s doc for why.
        pullQueue.async { [pullProvider, logger] in
            let onProgress: @Sendable (UInt64, UInt64) -> Void = { bytes, total in
                pusher?.record(bytesTransferred: bytes, totalBytes: total)
            }
            switch pullProvider.fetchStagedFile(
                generation: generation, repIndex: repIndex, onProgress: onProgress)
            {
            case .success(let path):
                logger.debug("Relay staged \(path, privacy: .public)")
                reply(path, nil)
            case .failure(let error):
                logger.error(
                    "Relay fetchFile failed: \(String(describing: error), privacy: .public)")
                reply(nil, Self.nsError(for: error))
            }
        }
    }

    /// Relays a best-effort cancel to the owner's pull provider.
    ///
    /// Dispatched onto `pullQueue`, the same as `fetchFile`, rather than run
    /// directly on the connection's serial delivery queue: `cancelStagedPull`
    /// bottoms out in a vsock write (`ClipboardStreamReceiver.cancel(transferID:)`
    /// sending a `ClipboardStreamAbort`) that can block for real time against a
    /// stalled peer, and this delivery queue is shared with every other
    /// `fetchFile`/`cancelFetch` on the connection — blocking it here would
    /// reintroduce exactly the starvation problem moving `fetchFile` off the
    /// queue was meant to solve.
    public func cancelFetch(generation: UInt64, repIndex: Int) {
        logger.debug(
            "Relay cancelFetch (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public))"
        )
        pullQueue.async { [pullProvider] in
            pullProvider.cancelStagedPull(generation: generation, repIndex: repIndex)
        }
    }

    /// Pulls one child file of a directory rep's placeholder tree through the
    /// owner and replies with the staged path (folder D1b).
    ///
    /// Mirrors `fetchFile`.
    public func fetchChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        logger.debug(
            "Relay fetchChild (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public), seq=\(childSeq, privacy: .public))"
        )
        let pusher = NSXPCConnection.current().map {
            FetchProgressPusher(
                connection: $0, generation: generation, repIndex: repIndex, childSeq: childSeq,
                logger: logger)
        }
        pullQueue.async { [pullProvider, logger] in
            let onProgress: @Sendable (UInt64, UInt64) -> Void = { bytes, total in
                pusher?.record(bytesTransferred: bytes, totalBytes: total)
            }
            switch pullProvider.fetchStagedChild(
                generation: generation, repIndex: repIndex, childSeq: childSeq,
                relativePath: relativePath, onProgress: onProgress)
            {
            case .success(let path):
                logger.debug("Relay staged child \(path, privacy: .public)")
                reply(path, nil)
            case .failure(let error):
                logger.error(
                    "Relay fetchChild failed: \(String(describing: error), privacy: .public)")
                reply(nil, Self.nsError(for: error))
            }
        }
    }

    /// Relays a best-effort child-fetch cancel to the owner's pull provider.
    public func cancelChildFetch(generation: UInt64, repIndex: Int, childSeq: UInt32) {
        logger.debug(
            "Relay cancelChildFetch (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public), seq=\(childSeq, privacy: .public))"
        )
        pullQueue.async { [pullProvider] in
            pullProvider.cancelStagedChildPull(
                generation: generation, repIndex: repIndex, childSeq: childSeq)
        }
    }

    private static func nsError(for error: FileProviderPullError) -> NSError {
        let code: NSFileProviderError.Code
        switch error {
        case .noCurrentOffer: code = .noSuchItem
        case .pullFailed: code = .serverUnreachable
        }
        return NSError(domain: NSFileProviderErrorDomain, code: code.rawValue)
    }
}
