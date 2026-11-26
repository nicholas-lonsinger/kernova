import Foundation

/// What a wire client is asking the app to read on its behalf.
///
/// The app puts a different question to the user for each, so the request says
/// which rather than leaving the panel to guess.
package enum SandboxedSource: Sendable {
    /// A `.kernova` bundle the library copies in and never opens again.
    case vmBundle
    /// A folder a VM shares with its guest, reopened at every boot.
    case sharedDirectory
}

/// Gets this sandboxed process read access to a path a caller named.
///
/// A wire client names its file as a string: the `kernova` tool is sandboxed
/// with no file access of its own, so it holds no grant it could hand over and
/// the app is what has to obtain one.
@MainActor
package protocol SandboxSourceAuthorizing: AnyObject {
    /// Returns once the app may read `url`, asking the user when the sandbox
    /// does not already admit it, and throws when it still may not.
    func requireReadAccess(to url: URL, as source: SandboxedSource) async throws
}
