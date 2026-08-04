import Foundation

// Shared container-app ↔ File Provider extension XPC contract.
//
// The extension is sandboxed and cannot open a vsock, so on `fetchContents` it
// relays the byte pull to the process owning the vsock clipboard connection over
// the `NSFileProviderServicing` anonymous-XPC pipe (CLIPBOARD.md §11). The owner
// is the XPC client and *exports* this interface; the extension calls it *back*
// through the accepted connection. The relay carries only the addressing
// `(generation, repIndex)` and replies with a *path* — never the bytes.

/// The XPC interface the container app exports to the File Provider extension.
@objc public protocol FileProviderRelay {
    /// Pulls the file representation addressed by `(generation, repIndex)` over
    /// vsock, stages it into the shared app-group container, and replies with the
    /// staged file's path (which the sandboxed extension can read), or an
    /// `NSError` mapped to an `NSFileProviderError` on failure.
    ///
    /// The owner's implementation must dispatch the pull off the XPC delivery
    /// queue and reply asynchronously — see `cancelFetch` for why blocking it is
    /// not safe. `repIndex` is a non-negative `Int`.
    func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (_ stagedPath: String?, _ error: NSError?) -> Void)

    /// Best-effort abort of an in-flight `fetchFile` for `(generation, repIndex)`,
    /// so the owner stops streaming bytes a cancelled fetch will never read.
    /// One-way (no reply) and idempotent.
    ///
    /// Delivered on the same per-connection serial queue as `fetchFile`
    /// (`NSXPCConnection` delivers every incoming call and reply block on one
    /// private serial queue per connection — WWDC 2012 session 241), which is why
    /// `fetchFile` must not block that queue for the whole pull.
    func cancelFetch(generation: UInt64, repIndex: Int)
}

/// The XPC interface the File Provider extension exports to the container app.
///
/// An `NSXPCListener` only delivers `shouldAcceptNewConnection` when the *client*
/// sends its first message, and the owner (client) otherwise only exports
/// `FileProviderRelay` and waits to be called back — so it must call
/// `ownerDidConnect()` immediately after connecting or the extension's listener
/// never accepts the connection. The call doubles as the owner's liveness probe:
/// one that errors means the cached connection is dead and must be replaced.
@objc public protocol FileProviderControl {
    /// Activation handshake — the body is trivial; the send itself is the signal.
    func ownerDidConnect(reply: @escaping @Sendable () -> Void)
}
