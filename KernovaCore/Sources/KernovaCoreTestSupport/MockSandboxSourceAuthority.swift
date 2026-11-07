import Foundation

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

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

    /// A panel the user never answers: set, each request parks here until the
    /// task asking is cancelled, then throws `CancellationError`.
    var parkUntilCancelled: CancellationPark?

    /// A panel the test answers when it chooses: set, each request waits
    /// until ``releasePanel()`` and then answers as usual. What the test does
    /// meanwhile runs in its own task, not the request's.
    var holdsPanel = false
    private var heldPanels: [CheckedContinuation<Void, Never>] = []

    /// Fires when a request arrives, so a test awaits the verb reaching the
    /// panel.
    let requested = AsyncGate()

    private(set) var requests: [(url: URL, source: SandboxedSource)] = []

    var requestedURLs: [URL] { requests.map(\.url) }

    /// Lets every request ``holdsPanel`` is holding answer.
    func releasePanel() {
        let held = heldPanels
        heldPanels.removeAll()
        held.forEach { $0.resume() }
    }

    func readableURL(for url: URL, as source: SandboxedSource) async throws -> URL {
        requests.append((url, source))
        requested.notify()
        if let parkUntilCancelled {
            await parkUntilCancelled.park()
            throw CancellationError()
        }
        if holdsPanel {
            await withCheckedContinuation { heldPanels.append($0) }
        }
        whilePanelStands?()
        if let error { throw error }
        return substitute ?? url
    }
}
