import Darwin
import Foundation

@testable import Kernova

/// A ``PeerAuthorizing`` double whose verdict the test sets.
///
/// Lock-guarded rather than `@MainActor`: production calls it from the socket
/// queue while the test holds the main actor, so a main-bound double would be
/// unanswerable exactly when the subject asks.
final class MockPeerAuthorizer: PeerAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var authorized: Bool
    private var asked = 0

    /// What ``isAuthorized(peer:)`` answers.
    var isAuthorizedResult: Bool {
        get { lock.withLock { authorized } }
        set { lock.withLock { authorized = newValue } }
    }

    /// How many peers have been checked.
    var checkCount: Int { lock.withLock { asked } }

    init(isAuthorizedResult: Bool = true) {
        self.authorized = isAuthorizedResult
    }

    func isAuthorized(peer token: audit_token_t) -> Bool {
        lock.withLock {
            asked += 1
            return authorized
        }
    }
}
