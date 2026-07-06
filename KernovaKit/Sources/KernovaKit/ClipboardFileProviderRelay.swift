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
// old Mach design). See `ClipboardFileProviderServiceSource` (extension side) and
// `ClipboardFileProviderServicingConnector` (owner side).
//
// The relay carries only the addressing `(generation, repIndex)` and replies
// with a *path* — never the bytes. The owning process pulls the rep over vsock
// and stages it into the shared app-group container, which the sandboxed
// extension can read (its `application-groups` entitlement grants access). The
// extension then clones that file into the domain's `temporaryDirectoryURL()`
// before handing it to the system, so no payload ever crosses the XPC boundary
// and the staging cache is decoupled from the system's clone timing.

/// The XPC interface the container app exports to the File Provider extension.
@objc public protocol ClipboardFileProviderRelay {
    /// Pulls the file representation addressed by `(generation, repIndex)` over
    /// vsock, stages it into the shared app-group container, and replies with the
    /// staged file's path (which the sandboxed extension can read), or an
    /// `NSError` mapped to an `NSFileProviderError` on failure.
    ///
    /// Called on `fetchContents`; the File Provider read path has no 60s deadline,
    /// so blocking on the reply is safe. `repIndex` is a non-negative `Int`.
    func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (_ stagedPath: String?, _ error: NSError?) -> Void)
}

/// The XPC interface the File Provider extension exports to the container app.
///
/// An `NSXPCListener` only delivers `shouldAcceptNewConnection` when the *client*
/// sends its first message. In the inverted relay the owner (client) otherwise
/// sends nothing — it only exports `ClipboardFileProviderRelay` and waits to be
/// called back — so the extension's listener would never accept the connection and
/// could never call back. The owner calls `ownerDidConnect()` immediately after it
/// connects to drive that acceptance (the "app calls the service" message the
/// servicing pattern relies on). This is also the owner's liveness probe: a call
/// that errors means the cached connection is dead and must be replaced.
@objc public protocol ClipboardFileProviderControl {
    /// Activation handshake: the owner calls this right after connecting and
    /// exporting its relay, so the extension accepts the connection and can call
    /// the relay back. The body is intentionally trivial — the send itself is the
    /// signal.
    func ownerDidConnect(reply: @escaping @Sendable () -> Void)
}
