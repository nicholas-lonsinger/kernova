import Foundation

@testable import Kernova

/// In-memory stand-in for the open panel the sandbox authority puts up: it
/// records what it was asked about and answers the same URL, a substitute, or
/// a refusal.
///
/// `@MainActor` like the protocol, so no lock is needed: every call arrives on
/// the test's own isolation.
@MainActor
final class MockSandboxSourceAuthority: SandboxSourceAuthorizing {
    /// What to answer with instead of the URL asked about — the different file
    /// a user picks in the panel. The URL asked about, when unset.
    var substitute: URL?

    /// The refusal a dismissed panel raises.
    var error: (any Error)?

    /// Runs before the answer — in place of whatever a user does while the
    /// panel stands, starting the VM the caller named above all.
    var whilePanelStands: (@MainActor () -> Void)?

    private(set) var requests: [(url: URL, source: SandboxedSource)] = []

    var requestedURLs: [URL] { requests.map(\.url) }

    func readableURL(for url: URL, as source: SandboxedSource) async throws -> URL {
        requests.append((url, source))
        whilePanelStands?()
        if let error { throw error }
        return substitute ?? url
    }
}
