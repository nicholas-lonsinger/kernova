import Foundation

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

/// Inspector stand-in that stays inside `inspect` until the test releases it,
/// the way a multi-gigabyte image keeps the real one busy for seconds.
final class SuspendingMockLocalRestoreImageInspector: LocalRestoreImageInspecting, @unchecked Sendable {
    let inspectResult = InspectedRestoreImage(
        version: "15.6.1", build: "24G90", isSupportedOnThisHost: true)
    private let gate = AsyncGate()
    private let lock = NSLock()
    private var isInspecting = false
    private var isReleased = false

    func inspect(_ url: URL) async throws -> InspectedRestoreImage {
        lock.withLock { self.isInspecting = true }
        gate.notify()
        try? await gate.wait(until: { self.lock.withLock { self.isReleased } })
        return inspectResult
    }

    /// Suspends until `inspect` is in flight.
    func waitUntilInspecting() async throws {
        try await gate.wait(until: { self.lock.withLock { self.isInspecting } })
    }

    /// Lets the in-flight inspection finish.
    func release() {
        lock.withLock { self.isReleased = true }
        gate.notify()
    }
}
