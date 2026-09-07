import Foundation

@testable import Kernova

/// In-memory stand-in for the open panel an import's file authority puts up:
/// it records what it was asked about and answers the same URL, a substitute,
/// or a refusal.
///
/// `@MainActor` like the protocol, so no lock is needed: every call arrives on
/// the test's own isolation.
@MainActor
final class MockImportSourceAuthority: ImportSourceAuthorizing {
    /// What to answer with instead of the URL asked about — the different file
    /// a user picks in the panel. The URL asked about, when unset.
    var substitute: URL?

    /// The refusal a dismissed panel raises.
    var error: (any Error)?

    private(set) var requestedURLs: [URL] = []

    func readableURL(for url: URL) async throws -> URL {
        requestedURLs.append(url)
        if let error { throw error }
        return substitute ?? url
    }
}
