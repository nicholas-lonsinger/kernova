import Foundation

// Shared container-app ↔ File Provider extension XPC contract (issues #376
// guest / #424 host).
//
// The File Provider extension is sandboxed and cannot open a vsock, so on
// `fetchContents` it relays the byte pull to the process that owns the vsock
// clipboard connection — the guest agent (host→guest) or the main app
// (guest→host) — over an app-group-scoped Mach service (CLIPBOARD.md §11). The
// guest agent vends the service directly via its LaunchAgent plist's
// `MachServices` key; the main app, which is neither sandboxed nor
// launchd-managed, cannot register a Mach service itself, so an SMAppService
// LaunchAgent broker vends it and forwards to the app (#424 Phase 2b). Either
// way the sandboxed extension may look the service up because its name is
// prefixed by an app group both processes share.
//
// The relay carries only the addressing `(generation, repIndex)` and replies
// with a *path* — never the bytes. The owning process pulls the rep over vsock
// and stages it into the shared app-group container, which the sandboxed
// extension can read (its `application-groups` entitlement grants access). The
// extension then clones that file into the domain's `temporaryDirectoryURL()`
// before handing it to the system, so no payload ever crosses the XPC boundary
// and the staging cache is decoupled from the system's clone timing.

/// The XPC interface the container app (or its broker) exports to the File
/// Provider extension.
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
