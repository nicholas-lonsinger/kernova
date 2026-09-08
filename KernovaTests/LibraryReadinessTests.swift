import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// The one library-read await every automation front door shares.
@Suite("Library readiness", .admissionGated)
@MainActor
struct LibraryReadinessTests {
    /// A library read the test lands when it chooses.
    private final class LibraryRead: @unchecked Sendable {
        private let gate = AsyncGate()
        private let lock = NSLock()
        private var landed = false

        func wait() async {
            try? await gate.wait { self.lock.withLock { self.landed } }
        }

        func land() {
            lock.withLock { landed = true }
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
