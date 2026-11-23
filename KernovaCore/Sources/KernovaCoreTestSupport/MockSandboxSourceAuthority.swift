import Foundation

@testable import KernovaCore

/// In-memory stand-in for the open panel the sandbox authority puts up: it
/// records what it was asked about and answers the same URL.
///
/// `@MainActor` like the protocol, so no lock is needed: every call arrives on
/// the test's own isolation.
@MainActor
final class MockSandboxSourceAuthority: SandboxSourceAuthorizing {
    private(set) var requests: [(url: URL, source: SandboxedSource)] = []

    var requestedURLs: [URL] { requests.map(\.url) }

    func readableURL(for url: URL, as source: SandboxedSource) async throws -> URL {
        requests.append((url, source))
        return url
    }
}
