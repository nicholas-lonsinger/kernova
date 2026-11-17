import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// The one library-read await every automation front door shares.
@Suite("Library readiness", .caseScoped)
@MainActor
struct LibraryReadinessTests {
    /// A library read the test lands when it chooses.
    @MainActor
    private final class LibraryRead {
        private let gate = AsyncGate()
        private var landed = false
        /// Where a read no test lands fails the test.
        private let waits = OffTaskWaits()

        func wait() async {
            await waits.run { try await gate.wait { self.landed } }
        }

        func land() {
            landed = true
            gate.notify()
        }
    }

    @Test("The landing is on record only once the read has landed")
    func hasLandedFollowsTheRead() async throws {
        let read = LibraryRead()
        let readiness = LibraryReadiness(awaitReady: { await read.wait() })
        #expect(!readiness.hasLanded)

        read.land()
        try await Backstop("LibraryReadiness.ready()").run { await readiness.ready() }

        #expect(readiness.hasLanded)
    }
}
