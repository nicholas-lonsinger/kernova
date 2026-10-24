import Foundation
import KernovaSynchronization
import Testing

@testable import KernovaKit

/// A drag naming's hold on the main thread at the run loop's base, where
/// `NestedEventLoopWait.current()` would vend an event-loop wait. It needs a
/// live `NSApplication`, which only this app-hosted bundle has.
@Suite("ClipboardDragNaming on the main thread", .caseScoped)
@MainActor
struct ClipboardDragNamingMainThreadTests {
    @Test("a naming parks the main thread: a block performed on the main run loop does not run inside it")
    func namingParksTheMainThread() {
        let naming = ClipboardDragNaming()
        naming.track(generation: 1, promised: [0: false])
        let ran = Locked(false)
        // Scheduled before the hold, and the only thing that could answer it:
        // an event-loop wait runs it and is answered, a parked one cannot.
        RunLoop.main.perform {
            ran.withLock { $0 = true }
            naming.acknowledged(generation: 1)
        }

        // The deadline is the behavior under test: it is what ends a parked
        // hold here.
        let failure = naming.begin(generation: 1, deadline: .now() + 0.3, send: { true }) {
            Issue.record("Nothing answered the resolve, so nothing is released")
        }

        #expect(failure == .timedOut)
        #expect(!ran.withLock { $0 })
    }
}
