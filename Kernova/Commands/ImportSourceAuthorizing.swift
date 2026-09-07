import Foundation

/// Turns a path a caller named into a URL this sandboxed process may read.
///
/// A wire client names its bundle as a string: the `kernova` tool is sandboxed
/// with no file access of its own, so it holds no grant it could hand over and
/// the app is what has to obtain one.
@MainActor
protocol ImportSourceAuthorizing: AnyObject {
    /// Answers a URL the app may read `url`'s package through, asking the user
    /// when the sandbox does not already admit it.
    func readableURL(for url: URL) async throws -> URL
}
