import Foundation

// Shared agent ↔ File Provider extension XPC contract (issue #376).
//
// The File Provider extension is sandboxed and cannot open a vsock, so on
// `fetchContents` it relays the byte pull to the guest agent — which owns the
// vsock clipboard connection — over an app-group-scoped Mach service
// (CLIPBOARD.md §11). The agent vends the service via its LaunchAgent plist's
// `MachServices` key; the sandboxed extension may look it up because the service
// name is prefixed by an app group both processes share.
//
// The relay carries only the addressing `(generation, repIndex)` and replies
// with a *path* — never the bytes. The agent pulls the rep over vsock and stages
// it into the shared app-group container, which the sandboxed extension can read
// (its `application-groups` entitlement grants access). The extension then clones
// that file into the domain's `temporaryDirectoryURL()` before handing it to the
// system, so no payload ever crosses the XPC boundary and the agent's staging
// cache is decoupled from the system's clone timing.

/// Configuration shared by both ends of the relay.
public enum ClipboardFileProviderRelayConfig {
    /// The Mach service the agent vends and the extension connects to.
    ///
    /// Must be prefixed by the shared app group so the sandboxed extension can
    /// look it up.
    public static let machServiceName = "8MT4P4GZL2.app.kernova.relay"

    /// The app group shared by the agent and the extension.
    ///
    /// Team-ID-prefixed (macOS-style) so macOS grants implicit access without a
    /// device-limited provisioning profile — letting the agent run in any guest VM.
    public static let appGroupIdentifier = "8MT4P4GZL2.app.kernova"
}

/// The XPC interface the agent exports to the File Provider extension.
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
