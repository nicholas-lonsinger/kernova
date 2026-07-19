import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Unit tests for `HostClipboardPullRouter` (#464 review fix) — specifically
/// that `cancelStagedPull` reaches the service that actually dispatched a
/// given `(generation, repIndex)` pull, not whichever service happens to be
/// `source` *now*.
///
/// `HostClipboardFileProvider` is a single app-wide singleton router shared
/// across every VM's clipboard service ("the last Copy to Mac wins" — see its
/// doc comment), and a slow pull can run for a long time. Before this fix, a
/// cancel for VM A's still-in-flight pull would forward to whichever VM last
/// published — silently no-op'ing (VM A's real transfer keeps streaming) or,
/// worse, aborting an unrelated live transfer on VM B if their small per-VM
/// generation counters happened to collide.
@MainActor
@Suite("HostClipboardPullRouter")
struct HostClipboardPullRouterTests {
    /// Records `pullStagedFile`/`cancelStagedPull` calls so a test can assert
    /// which mock service actually received them.
    private final class MockSource: HostClipboardFileRepProviding, @unchecked Sendable {
        let label: String
        private let lock = NSLock()
        private var cancelCallStorage: (UInt64, Int)?
        var cancelCall: (UInt64, Int)? { lock.withLock { cancelCallStorage } }

        init(label: String) {
            self.label = label
        }

        func pullStagedFile(
            generation: UInt64, repIndex: Int,
            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
        ) -> Result<String, FileProviderPullError> {
            .success("/staged/\(label)")
        }

        func cancelStagedPull(generation: UInt64, repIndex: Int) {
            lock.withLock { cancelCallStorage = (generation, repIndex) }
        }

        func pullStagedChild(
            generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
        ) -> Result<String, FileProviderPullError> {
            .success("/staged/\(label)/child")
        }

        func cancelStagedChildPull(generation: UInt64, repIndex: Int, childSeq: UInt32) {
            lock.withLock { cancelCallStorage = (generation, repIndex) }
        }

        // Unused by the router tests, which exercise only the relay pull path.
        func copyToMacFileURL(generation: UInt64, repIndex: Int) -> URL? { nil }
    }

    /// A source whose `pullStagedFile` blocks until released, so a test can
    /// exercise a pull that's genuinely still in flight — matching a real
    /// vsock pull, which can run for a long time (that's the whole reason
    /// #464 exists), rather than a mock that returns (and clears its
    /// `dispatchedSources` entry) before the test ever gets to cancel it.
    private final class BlockingMockSource: HostClipboardFileRepProviding, @unchecked Sendable {
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var hasEnteredStorage = false
        private var cancelCallStorage: (UInt64, Int)?
        let entered = AsyncGate()
        var hasEntered: Bool { lock.withLock { hasEnteredStorage } }
        var cancelCall: (UInt64, Int)? { lock.withLock { cancelCallStorage } }

        func pullStagedFile(
            generation: UInt64, repIndex: Int,
            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
        ) -> Result<String, FileProviderPullError> {
            lock.withLock { hasEnteredStorage = true }
            entered.notify()
            releaseSemaphore.wait()
            return .success("/staged/blocked")
        }

        func cancelStagedPull(generation: UInt64, repIndex: Int) {
            lock.withLock { cancelCallStorage = (generation, repIndex) }
        }

        func pullStagedChild(
            generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
        ) -> Result<String, FileProviderPullError> {
            lock.withLock { hasEnteredStorage = true }
            entered.notify()
            releaseSemaphore.wait()
            return .success("/staged/blocked/child")
        }

        func cancelStagedChildPull(generation: UInt64, repIndex: Int, childSeq: UInt32) {
            lock.withLock { cancelCallStorage = (generation, repIndex) }
        }

        // Unused by the router tests, which exercise only the relay pull path.
        func copyToMacFileURL(generation: UInt64, repIndex: Int) -> URL? { nil }

        func release() {
            releaseSemaphore.signal()
        }
    }

    @Test("cancelStagedPull reaches the service that dispatched the pull, not a later current source")
    func cancelRoutesToDispatchingServiceNotCurrentSource() async throws {
        let router = HostClipboardPullRouter()
        let vmA = BlockingMockSource()
        let vmB = MockSource(label: "vmB")

        // VM A publishes and its pull is dispatched (captures `vmA` as the
        // service handling generation 1) — and is still genuinely in flight,
        // blocked exactly like a real, slow vsock pull.
        router.setSource(vmA)
        let fetchTask = Task {
            _ = await offCooperativePool { router.fetchStagedFile(generation: 1, repIndex: 0) }
        }
        try await vmA.entered.wait { vmA.hasEntered }

        // Before VM A's pull finishes, the user switches to VM B and copies
        // something there — VM B republishes, becoming the router's current
        // source (its own generation counter also starts at 1, so this is the
        // realistic collision case, not a contrived one).
        router.setSource(vmB)

        // A cancel for VM A's still-in-flight pull must reach vmA, not the
        // now-current vmB.
        router.cancelStagedPull(generation: 1, repIndex: 0)

        #expect(vmA.cancelCall?.0 == 1)
        #expect(vmA.cancelCall?.1 == 0)
        #expect(vmB.cancelCall == nil)

        vmA.release()
        _ = await fetchTask.value
    }

    @Test("cancelStagedPull falls back to the current source for a generation never dispatched")
    func cancelFallsBackToCurrentSourceForUnknownGeneration() {
        let router = HostClipboardPullRouter()
        let vmA = MockSource(label: "vmA")
        router.setSource(vmA)

        // No `fetchStagedFile` call ever recorded generation 5 — mirrors a
        // cancel that arrives for a pull the router never tracked (matches
        // `fetchStagedFile`'s own `.noCurrentOffer` fallback for an unknown
        // generation: best-effort, not a hard requirement of prior tracking).
        router.cancelStagedPull(generation: 5, repIndex: 0)

        #expect(vmA.cancelCall?.0 == 5)
        #expect(vmA.cancelCall?.1 == 0)
    }

    @Test("the dispatched-source entry is cleared once its fetch returns")
    func dispatchedSourceEntryClearsAfterFetch() {
        let router = HostClipboardPullRouter()
        let vmA = MockSource(label: "vmA")
        let vmB = MockSource(label: "vmB")

        router.setSource(vmA)
        _ = router.fetchStagedFile(generation: 2, repIndex: 0)
        // vmA's fetch has already returned (synchronous mock) — its dispatched
        // entry for generation 2 should no longer be tracked, so a later cancel
        // for the same generation (now stale/unknown to the router) falls back
        // to whichever source is current, exactly like an unknown generation.
        router.setSource(vmB)

        router.cancelStagedPull(generation: 2, repIndex: 0)

        #expect(vmB.cancelCall?.0 == 2)
        #expect(vmA.cancelCall == nil)
    }

    @Test("clearSource(ifCurrently:) only clears when the given source is still current")
    func clearSourceOnlyAffectsCurrentSource() {
        let router = HostClipboardPullRouter()
        let vmA = MockSource(label: "vmA")
        let vmB = MockSource(label: "vmB")

        router.setSource(vmA)
        router.setSource(vmB)
        router.clearSource(ifCurrently: vmA)  // stale — vmB is current now

        #expect(router.isCurrent(vmB))
    }
}
