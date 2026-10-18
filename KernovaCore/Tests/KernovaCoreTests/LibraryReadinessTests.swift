import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The one library-read await every automation front door shares.
@Suite("Library readiness", .caseScoped)
@MainActor
struct LibraryReadinessTests {
    /// Counts the awaits the readiness makes of the library read.
    private actor Counter {
        private(set) var value = 0

        func increment() { value += 1 }
    }

    /// A library read the test lands when it chooses.
    @MainActor
    private final class LibraryRead {
        private let gate = AsyncGate()
        private var landed = false

        func wait() async {
            try? await gate.wait { self.landed }
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
        await readiness.ready()

        #expect(readiness.hasLanded)
    }

    @Test("Every caller returns once the read lands, on one await of the read")
    func callersShareOneAwait() async throws {
        let awaits = Counter()
        let readiness = LibraryReadiness(awaitReady: { await awaits.increment() })

        await readiness.ready()
        await readiness.ready()

        #expect(readiness.hasLanded)
        #expect(await awaits.value == 1)
    }
}
