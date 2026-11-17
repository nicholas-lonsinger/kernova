import Foundation

@testable import KernovaCore

/// A ``PeerAuthorizing`` double whose verdict the test picks when creating it.
///
/// Lock-guarded rather than `@MainActor`: production calls it from the socket
/// queue while the test holds the main actor, so a main-bound double would be
/// unanswerable exactly when the subject asks.
final class MockPeerAuthorizer: PeerAuthorizing {
    private let verdict: PeerAuthorization

    init(_ verdict: PeerAuthorization = .authorized) {
        self.verdict = verdict
    }

    func authorization(ofPeer token: audit_token_t) -> PeerAuthorization {
        verdict
    }
}
