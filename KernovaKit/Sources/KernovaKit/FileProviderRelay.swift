import Foundation

// Shared container-app ↔ File Provider extension XPC contract (issues #376
// guest / #424 host / #460 servicing migration).
//
// The File Provider extension is sandboxed and cannot open a vsock, so on
// `fetchContents` it relays the byte pull to the process that owns the vsock
// clipboard connection — the guest agent (host→guest) or the main app
// (guest→host) — over the canonical `NSFileProviderServicing` anonymous-XPC pipe
// (CLIPBOARD.md §11). The owner is the XPC client and *exports* this interface;
// the extension calls it *back* through the accepted connection (inverted vs. the
// old Mach design). See `FileProviderServiceSource` (extension side) and
// `FileProviderServicingConnector` (owner side).
//
// The relay carries only the addressing `(generation, repIndex)` and replies
// with a *path* — never the bytes. The owning process pulls the rep over vsock
// and stages it into the shared app-group container, which the sandboxed
// extension can read (its `application-groups` entitlement grants access). The
// extension then clones that file into the domain's `temporaryDirectoryURL()`
// before handing it to the system, so no payload ever crosses the XPC boundary
// and the staging cache is decoupled from the system's clone timing.

/// The XPC interface the container app exports to the File Provider extension.
@objc public protocol FileProviderRelay {
    /// Pulls the file representation addressed by `(generation, repIndex)` over
    /// vsock, stages it into the shared app-group container, and replies with the
    /// staged file's path (which the sandboxed extension can read), or an
    /// `NSError` mapped to an `NSFileProviderError` on failure.
    ///
    /// Called on `fetchContents`; the File Provider read path has no 60s deadline.
    /// The owner's implementation dispatches the pull off the XPC delivery queue
    /// and replies asynchronously — see `cancelFetch` for why blocking it is not
    /// safe. `repIndex` is a non-negative `Int`.
    func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (_ stagedPath: String?, _ error: NSError?) -> Void)

    /// Best-effort abort of an in-flight `fetchFile` for `(generation, repIndex)`,
    /// so the owner stops streaming bytes a cancelled fetch will never read
    /// (#464). One-way (no reply) and idempotent — a cancel for an unknown or
    /// already-finished transfer is a no-op.
    ///
    /// Delivered on the same per-connection serial queue as `fetchFile`
    /// (`NSXPCConnection` delivers every incoming call and reply block on one
    /// private serial queue per connection — WWDC 2012 session 241). Because
    /// `fetchFile`'s owner-side implementation must not block that queue for the
    /// whole pull, this call can reach the owner while a fetch is still in
    /// flight.
    func cancelFetch(generation: UInt64, repIndex: Int)

    /// Pulls one **child** file of a directory rep's placeholder tree (folder
    /// D1b, `clipboard.dirtree.v1`): the owner walks/opens the confined child at
    /// `relativePath` within the source folder, streams it over vsock, stages it
    /// into the shared app-group container, and replies with the staged path (or
    /// an `NSError`). `childSeq` scopes the transfer distinctly from the rep and
    /// its siblings (see `ClipboardTransferID`). Same non-blocking contract as
    /// `fetchFile`.
    func fetchChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
        reply: @escaping @Sendable (_ stagedPath: String?, _ error: NSError?) -> Void)

    /// Best-effort abort of an in-flight `fetchChild` for `(generation, repIndex,
    /// childSeq)`. One-way and idempotent, exactly like `cancelFetch`.
    func cancelChildFetch(generation: UInt64, repIndex: Int, childSeq: UInt32)
}

/// The XPC interface the File Provider extension exports to the container app.
///
/// An `NSXPCListener` only delivers `shouldAcceptNewConnection` when the *client*
/// sends its first message. In the inverted relay the owner (client) otherwise
/// sends nothing — it only exports `FileProviderRelay` and waits to be
/// called back — so the extension's listener would never accept the connection and
/// could never call back. The owner calls `ownerDidConnect()` immediately after it
/// connects to drive that acceptance (the "app calls the service" message the
/// servicing pattern relies on). This is also the owner's liveness probe: a call
/// that errors means the cached connection is dead and must be replaced.
@objc public protocol FileProviderControl {
    /// Activation handshake: the owner calls this right after connecting and
    /// exporting its relay, so the extension accepts the connection and can call
    /// the relay back. The body is intentionally trivial — the send itself is the
    /// signal.
    func ownerDidConnect(reply: @escaping @Sendable () -> Void)

    /// One-way progress push for an in-flight `fetchFile` pull (#426), so the
    /// extension can drive a byte-denominated `Progress` in `fetchContents` and
    /// Finder renders a *determinate* download bar instead of the pulsing
    /// indeterminate one. The owner pushes coalesced `(bytesTransferred,
    /// totalBytes)` from the receiver's per-chunk callback for the pull's
    /// duration, keyed by the same `(generation, repIndex)` addressing as
    /// `fetchFile`; the extension routes it to that pull's registered handler.
    ///
    /// One-way (no reply) and best-effort, exactly like `cancelFetch`: a push
    /// for an unknown or already-finished pull is a no-op on the extension side,
    /// and a version-skewed extension that predates this selector simply drops
    /// the message — `NSXPCConnection` discards an unrecognized incoming call
    /// without tearing the connection down — so a missing peer degrades to
    /// no-progress rather than breaking the fetch.
    ///
    /// Delivered on the connection's serial delivery queue (like every incoming
    /// call), so it can arrive interleaved with the owner's other traffic; it
    /// never blocks — the handler only advances an `NSProgress`.
    func fetchProgressed(
        generation: UInt64, repIndex: Int, bytesTransferred: UInt64, totalBytes: UInt64)

    /// The `fetchChild` counterpart of `fetchProgressed`, keyed additionally by
    /// `childSeq` so a directory rep's concurrent child pulls drive their own
    /// determinate download bars (folder D1b). Same one-way, best-effort,
    /// version-skew-tolerant contract as `fetchProgressed`.
    func childFetchProgressed(
        generation: UInt64, repIndex: Int, childSeq: UInt32, bytesTransferred: UInt64,
        totalBytes: UInt64)
}
