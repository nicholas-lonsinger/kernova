import Foundation

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

/// Inspector stand-in that stays inside `inspect` until the test releases it,
/// the way a multi-gigabyte image keeps the real one busy for seconds.
@MainActor
final class SuspendingMockLocalRestoreImageInspector: LocalRestoreImageInspecting {
    let inspectResult = InspectedRestoreImage(
        version: "15.6.1", build: "24G90", isSupportedOnThisHost: true)
    private let gate = AsyncGate()
    private var isInspecting = false
    private var isReleased = false

    nonisolated init() {}

    func inspect(_ url: URL) async throws -> InspectedRestoreImage {
        isInspecting = true
        gate.notify()
        try? await gate.wait(until: { self.isReleased })
        return inspectResult
    }

    /// Suspends until `inspect` is in flight.
    func waitUntilInspecting() async throws {
        try await gate.wait(until: { self.isInspecting })
    }

    /// Lets the in-flight inspection finish.
    func release() {
        isReleased = true
        gate.notify()
    }
}
