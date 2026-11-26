import Foundation

@testable import KernovaCore

/// In-memory stand-in for the open panel the sandbox authority puts up: it
/// records what it was asked about and admits it.
///
/// `@MainActor` like the protocol, so no lock is needed: every call arrives on
/// the test's own isolation.
@MainActor
final class MockSandboxSourceAuthority: SandboxSourceAuthorizing {
    private(set) var requests: [(url: URL, source: SandboxedSource)] = []

    var requestedURLs: [URL] { requests.map(\.url) }

    func requireReadAccess(to url: URL, as source: SandboxedSource) async throws {
        requests.append((url, source))
    }
}
