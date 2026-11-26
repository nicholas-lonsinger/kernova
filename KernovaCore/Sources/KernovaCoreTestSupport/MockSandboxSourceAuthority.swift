import Foundation

@testable import KernovaCore

/// In-memory stand-in for the open panel the sandbox authority puts up: it
/// records what it was asked about and answers ``picked``, or the same URL.
///
/// `@MainActor` like the protocol, so no lock is needed: every call arrives on
/// the test's own isolation.
@MainActor
final class MockSandboxSourceAuthority: SandboxSourceAuthorizing {
    private(set) var requests: [(url: URL, source: SandboxedSource)] = []

    var requestedURLs: [URL] { requests.map(\.url) }

    /// The item the user picks in the panel whatever it asked about, `nil` to
    /// pick the one asked about.
    var picked: URL?

    func readableURL(for url: URL, as source: SandboxedSource) async throws -> URL {
        requests.append((url, source))
        return picked ?? url
    }
}
