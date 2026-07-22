import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `FetchProgressThrottle` (#426).
///
/// The pure decision behind the servicing-XPC progress push coalescing,
/// exercised in isolation so the throttle policy (forward progress required, ~1%
/// byte quantum OR ~100 ms, and always the final chunk) is locked without
/// standing up an XPC round trip.
@Suite("FetchProgressThrottle")
struct FetchProgressThrottleTests {
    private let total: UInt64 = 1_000_000

    @Test("the first forward chunk pushes (seeded with a large elapsed)")
    func firstForwardChunkPushes() {
        #expect(
            FetchProgressThrottle.shouldPush(
                bytes: 1, total: total, lastPushedBytes: 0,
                elapsedSinceLastPush: .greatestFiniteMagnitude))
    }

    @Test("no forward progress never pushes")
    func noForwardProgressDoesNotPush() {
        // Equal bytes — even past the time bound and even at the total.
        #expect(
            !FetchProgressThrottle.shouldPush(
                bytes: 500_000, total: total, lastPushedBytes: 500_000, elapsedSinceLastPush: 10))
        #expect(
            !FetchProgressThrottle.shouldPush(
                bytes: total, total: total, lastPushedBytes: total, elapsedSinceLastPush: 10))
        // Regressed bytes (a reordered callback) never push.
        #expect(
            !FetchProgressThrottle.shouldPush(
                bytes: 400_000, total: total, lastPushedBytes: 500_000, elapsedSinceLastPush: 10))
    }

    @Test("the final chunk always pushes, even below the byte and time thresholds")
    func finalChunkAlwaysPushes() {
        // One byte of forward progress, no time elapsed, delta far under 1% — but
        // it reaches the total, so it must push.
        #expect(
            FetchProgressThrottle.shouldPush(
                bytes: total, total: total, lastPushedBytes: total - 1, elapsedSinceLastPush: 0))
        // An overshoot past the total also counts as final.
        #expect(
            FetchProgressThrottle.shouldPush(
                bytes: total + 10, total: total, lastPushedBytes: total - 1,
                elapsedSinceLastPush: 0))
    }

    @Test("a sub-1% delta within the time bound does not push")
    func subQuantumWithinTimeBoundDoesNotPush() {
        // 0.5% of the total, only 50 ms since the last push (< 100 ms).
        #expect(
            !FetchProgressThrottle.shouldPush(
                bytes: 105_000, total: total, lastPushedBytes: 100_000, elapsedSinceLastPush: 0.05))
    }

    @Test("a >=1% delta within the time bound pushes")
    func atOrOverQuantumPushes() {
        // Exactly 1% of the total, well within the time bound.
        #expect(
            FetchProgressThrottle.shouldPush(
                bytes: 110_000, total: total, lastPushedBytes: 100_000, elapsedSinceLastPush: 0.01))
    }

    @Test("passing the time bound pushes even for a tiny delta")
    func timeBoundPushesTinyDelta() {
        #expect(
            FetchProgressThrottle.shouldPush(
                bytes: 100_001, total: total, lastPushedBytes: 100_000, elapsedSinceLastPush: 0.1))
    }

    @Test("an unknown total (0) pushes only on the time bound")
    func unknownTotalPushesOnlyOnTime() {
        // No total → no byte-fraction and no final-chunk shortcut; only time.
        #expect(
            !FetchProgressThrottle.shouldPush(
                bytes: 5_000, total: 0, lastPushedBytes: 0, elapsedSinceLastPush: 0.05))
        #expect(
            FetchProgressThrottle.shouldPush(
                bytes: 5_000, total: 0, lastPushedBytes: 0, elapsedSinceLastPush: 0.2))
    }
}

/// Unit tests for `FetchProgressCoalescer` — the stateful half of the throttle
/// (#634).
///
/// `FetchProgressThrottle` above is the pure decision; this owns the watermarks
/// it decides against, shared by the servicing-XPC push and the Finder-facing
/// published progress. Every case drives `now:` explicitly, so nothing here
/// depends on wall-clock timing or on how fast the runner happens to be.
@Suite("FetchProgressCoalescer")
struct FetchProgressCoalescerTests {
    private let total: UInt64 = 1_000_000

    /// A `DispatchTime` `nanoseconds` after an arbitrary fixed base.
    ///
    /// The coalescer only ever reads *differences* between the values it is
    /// handed, so the base is irrelevant as long as it is shared.
    private func time(_ nanoseconds: UInt64) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: 1_000_000_000 + nanoseconds)
    }

    @Test("the first call always emits — no prior emit means infinite elapsed")
    func firstCallAlwaysEmits() {
        let coalescer = FetchProgressCoalescer()
        // One byte, no time elapsed, far under the 1% quantum: it emits only
        // because there is no previous emit to measure against.
        #expect(coalescer.shouldEmit(bytes: 1, total: total, now: time(0)))
    }

    @Test("a same-byte repeat does not emit, however much time has passed")
    func sameByteRepeatDoesNotEmit() {
        let coalescer = FetchProgressCoalescer()
        #expect(coalescer.shouldEmit(bytes: 500_000, total: total, now: time(0)))
        #expect(!coalescer.shouldEmit(bytes: 500_000, total: total, now: time(0)))
        #expect(!coalescer.shouldEmit(bytes: 500_000, total: total, now: time(10_000_000_000)))
        // A regressed count (a reordered callback) is likewise not forward progress.
        #expect(!coalescer.shouldEmit(bytes: 400_000, total: total, now: time(10_000_000_000)))
    }

    @Test("the byte watermark advances with each emit")
    func byteWatermarkAdvances() {
        let coalescer = FetchProgressCoalescer()
        #expect(coalescer.shouldEmit(bytes: 100_000, total: total, now: time(0)))
        // 5,000 bytes past the new watermark is 0.5% — under the 1% quantum, and
        // only 50 ms later, so it is held back.
        #expect(!coalescer.shouldEmit(bytes: 105_000, total: total, now: time(50_000_000)))
        // 10,000 past the *watermark* (not past the last call) is exactly 1%.
        #expect(coalescer.shouldEmit(bytes: 110_000, total: total, now: time(60_000_000)))
        // …and that emit moved the watermark again: the same 5,000-byte step is
        // still under the quantum relative to 110,000.
        #expect(!coalescer.shouldEmit(bytes: 115_000, total: total, now: time(70_000_000)))
    }

    @Test("the time watermark advances with each emit, not with each call")
    func timeWatermarkAdvances() {
        let coalescer = FetchProgressCoalescer()
        #expect(coalescer.shouldEmit(bytes: 100_000, total: total, now: time(0)))
        #expect(!coalescer.shouldEmit(bytes: 100_001, total: total, now: time(50_000_000)))
        // 100 ms after the last *emit* — a tiny delta rides the time bound.
        #expect(coalescer.shouldEmit(bytes: 100_002, total: total, now: time(100_000_000)))
        // The bound is measured from that emit, so 50 ms later is too soon again.
        #expect(!coalescer.shouldEmit(bytes: 100_003, total: total, now: time(150_000_000)))
    }

    @Test("the final chunk emits regardless of the watermarks")
    func finalChunkEmits() {
        let coalescer = FetchProgressCoalescer()
        #expect(coalescer.shouldEmit(bytes: total - 1, total: total, now: time(0)))
        #expect(coalescer.shouldEmit(bytes: total, total: total, now: time(0)))
    }
}
