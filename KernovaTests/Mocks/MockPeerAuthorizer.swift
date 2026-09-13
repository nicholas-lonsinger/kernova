import Darwin
import Foundation

@testable import Kernova

/// A ``PeerAuthorizing`` double whose verdict the test picks when creating it.
///
/// Lock-guarded rather than `@MainActor`: production calls it from the socket
/// queue while the test holds the main actor, so a main-bound double would be
/// unanswerable exactly when the subject asks.
final class MockPeerAuthorizer: PeerAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private let verdict: PeerAuthorization
    private var asked = 0

    /// How many peers have been checked.
    var checkCount: Int { lock.withLock { asked } }

    init(_ verdict: PeerAuthorization = .authorized) {
        self.verdict = verdict
    }

    func authorization(ofPeer token: audit_token_t) -> PeerAuthorization {
        lock.withLock {
            asked += 1
            return verdict
        }
    }
}
