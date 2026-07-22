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

// MARK: - Offer URL index

/// The user-visible URL of each rep the current offer published, so an in-flight
/// pull can name the file it is materializing (#634).
///
/// A relay pull is addressed by `(generation, repIndex[, childSeq,
/// relativePath])`, but the progress Finder's copy dialog subscribes to is keyed
/// by the placeholder's *user-visible* URL under `~/Library/CloudStorage/…`.
/// `FileProviderDomainHost.publishItems` already mints exactly those URLs
/// (`rootURL.appendingPathComponent(filename)`, after the offer's within-offer
/// filename de-duplication) immediately before handing them to the pasteboard, so
/// this caches them there instead of re-deriving them at fetch time.
///
/// RATIONALE: deliberately NOT a `FileProviderContainer.readManifest()` lookup.
/// Reading the manifest per fetch would put synchronous JSON file I/O on the pull
/// path, and it would re-derive a URL the publish path had already computed — two
/// places that could disagree about the de-duplicated filename. Caching the
/// publish path's own output makes the two identical by construction.
///
/// `@unchecked Sendable`: the cached generation and URLs are guarded by `lock` —
/// the domain host writes them on the main queue while the relay reads them
/// off-main from `pullQueue`.
public final class FileProviderOfferURLIndex: @unchecked Sendable {
    private let lock = NSLock()
    /// The generation the cached `urls` belong to; `nil` when no offer is
    /// current.
    private var generation: UInt64?
    /// Root-level user-visible URL per rep index — a flat file's placeholder, or
    /// a directory rep's folder root.
    private var urls: [Int: URL] = [:]

    /// Creates an empty index, resolving nothing until an offer is published.
    public init() {}

    /// Replaces the cache with one offer generation's published URLs.
    ///
    /// Wholesale, not merged: a new offer supersedes the previous one entirely,
    /// so a rep index the new generation doesn't publish must stop resolving.
    func update(generation: UInt64, urls: [Int: URL]) {
        lock.withLock {
            self.generation = generation
            self.urls = urls
        }
    }

    /// Forgets the current offer, so nothing resolves until the next publish.
    func clear() {
        lock.withLock {
            generation = nil
            urls = [:]
        }
    }

    /// The user-visible URL of the file a pull is materializing: the root
    /// placeholder for a flat rep, or `<folder root>/<relativePath>` for a tree
    /// child (folder D1b). `nil` for a superseded/unknown generation.
    ///
    /// The generation match is required rather than best-effort: a pull for a
    /// generation that is no longer current is about to fail `noCurrentOffer`
    /// anyway, and publishing a bar against the *successor* offer's placeholder
    /// would put a phantom download on an unrelated file.
    func url(generation: UInt64, repIndex: Int, relativePath: String?) -> URL? {
        let root: URL? = lock.withLock {
            guard self.generation == generation else { return nil }
            return urls[repIndex]
        }
        guard let root else { return nil }
        guard let relativePath else { return root }
        // One component at a time: `appendingPathComponent("sub/file.txt")`
        // percent-escapes nothing but does treat the whole string as a single
        // component name, so the separator would have to survive by luck rather
        // than by construction.
        return relativePath.split(separator: "/").reduce(root) {
            $0.appendingPathComponent(String($1))
        }
    }
}

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
    /// Resolves an in-flight pull's addressing to the placeholder's user-visible
    /// URL, so the pull can publish a Finder-visible progress (#634).
    private let offerURLIndex: FileProviderOfferURLIndex

    /// Creates the relay service, logging under `loggerSubsystem`.
    ///
    /// `offerURLIndex` is the one the owning `FileProviderDomainHost` fills from
    /// `publishItems`; it defaults to a private empty index so a caller that
    /// never publishes (every unit test that drives the relay directly) simply
    /// resolves no URLs and publishes no Finder progress.
    public init(
        pullProvider: FileProviderPullProvider, loggerSubsystem: String,
        offerURLIndex: FileProviderOfferURLIndex = FileProviderOfferURLIndex()
    ) {
        self.logger = KernovaLogger(subsystem: loggerSubsystem, category: "FileProviderRelay")
        self.pullProvider = pullProvider
        self.offerURLIndex = offerURLIndex
        super.init()
    }

    /// Builds the Finder-facing published progress for one in-flight pull, or
    /// `nil` when the placeholder's URL can't be resolved.
    ///
    /// `nil` means the offer is gone, superseded, or was never published (no root
    /// yet) — the pull runs exactly as before, just without a copy-dialog bar.
    /// `onCancel` is dispatched onto `pullQueue` rather than run inline: a
    /// subscriber's cancel arrives on whatever thread `NSProgress` delivers it,
    /// and the cancel bottoms out in a vsock write that can block for real time
    /// against a stalled peer (see `cancelFetch`). The pull provider documents
    /// cancel as best-effort and idempotent, so this arriving alongside the
    /// extension's own `fetchContents` cancellation is harmless.
    private func makePublishedProgress(
        generation: UInt64, repIndex: Int, childSeq: UInt32? = nil, relativePath: String? = nil
    ) -> PublishedFetchProgress? {
        guard
            let url = offerURLIndex.url(
                generation: generation, repIndex: repIndex, relativePath: relativePath)
        else { return nil }
        let onCancel: @Sendable () -> Void = { [pullProvider, pullQueue] in
            pullQueue.async {
                if let childSeq {
                    pullProvider.cancelStagedChildPull(
                        generation: generation, repIndex: repIndex, childSeq: childSeq)
                } else {
                    pullProvider.cancelStagedPull(generation: generation, repIndex: repIndex)
                }
            }
        }
        return PublishedFetchProgress(fileURL: url, logger: logger, onCancel: onCancel)
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
        // The pusher drives the FP item's own badge; this drives Finder's copy
        // dialog, which does not consume the extension's `fetchContents`
        // `Progress` at all (#634). Both are fed from the one `onProgress` below.
        let publisher = makePublishedProgress(generation: generation, repIndex: repIndex)
        // Off the XPC delivery queue: the File Provider read path has no 60s
        // deadline so a long block is safe, but it must not be *this* queue — see
        // `pullQueue`'s doc for why.
        pullQueue.async { [pullProvider, logger] in
            // Every exit — success, failure, and a cancel (which surfaces as a
            // `.pullFailed` reply, so it flows through the same branches) — must
            // withdraw the published progress, or Finder's dialog keeps a bar for
            // a transfer that is over.
            defer { publisher?.finish() }
            let onProgress: @Sendable (UInt64, UInt64) -> Void = { bytes, total in
                pusher?.record(bytesTransferred: bytes, totalBytes: total)
                publisher?.record(bytesTransferred: bytes, totalBytes: total)
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
        // A tree child's placeholder lives at `<folder root>/<relativePath>`, so
        // that — not the folder root — is the URL Finder's dialog is watching
        // while this child materializes.
        let publisher = makePublishedProgress(
            generation: generation, repIndex: repIndex, childSeq: childSeq,
            relativePath: relativePath)
        pullQueue.async { [pullProvider, logger] in
            defer { publisher?.finish() }
            let onProgress: @Sendable (UInt64, UInt64) -> Void = { bytes, total in
                pusher?.record(bytesTransferred: bytes, totalBytes: total)
                publisher?.record(bytesTransferred: bytes, totalBytes: total)
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
