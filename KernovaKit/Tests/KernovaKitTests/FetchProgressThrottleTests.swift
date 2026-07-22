import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `FetchProgressThrottle` (#426).
///
/// The pure decision behind the servicing-XPC progress push coalescing,
/// exercised in isolation so the throttle policy (forward progress required, ~1%
/// byte quantum OR ~100 ms, and always the final chunk) is locked without
/// standing up an XPC round trip.
/// Unit tests for `FetchProgressCoalescer` — the stateful watermarks both
/// per-pull progress consumers share (#634).
///
/// The pure policy is locked by `FetchProgressThrottleTests`; this covers the
/// bookkeeping wrapped around it: advancing the last-forwarded byte count,
/// stamping the first update (the file publisher's reveal-gate reference), and
/// refusing a non-forward update.
@Suite("FetchProgressCoalescer")
struct FetchProgressCoalescerTests {
    private let total: UInt64 = 1_000_000

    @Test("the first update always forwards and stamps the reveal-gate reference")
    func firstUpdateForwardsAndStamps() {
        let coalescer = FetchProgressCoalescer()
        #expect(coalescer.firstUpdateTime == nil)
        #expect(coalescer.shouldForward(bytesTransferred: 1, totalBytes: total))
        #expect(coalescer.firstUpdateTime != nil)
    }

    @Test("the first-update stamp is set even when the update itself is refused")
    func refusedFirstUpdateStillStamps() {
        let coalescer = FetchProgressCoalescer()
        // Zero bytes is not forward progress, so the throttle refuses it — but
        // the pull has started, and the reveal gate measures from that moment.
        #expect(!coalescer.shouldForward(bytesTransferred: 0, totalBytes: total))
        #expect(coalescer.firstUpdateTime != nil)
    }

    @Test("the watermark advances, so a repeated byte count is refused")
    func watermarkAdvances() {
        let coalescer = FetchProgressCoalescer()
        #expect(coalescer.shouldForward(bytesTransferred: 500_000, totalBytes: total))
        // Same count again: no forward progress, and it isn't the final chunk.
        #expect(!coalescer.shouldForward(bytesTransferred: 500_000, totalBytes: total))
        // A regressed count (a reordered callback) is refused too.
        #expect(!coalescer.shouldForward(bytesTransferred: 400_000, totalBytes: total))
        // The final chunk always forwards, however close to the last one.
        #expect(coalescer.shouldForward(bytesTransferred: total, totalBytes: total))
    }

    @Test("the reveal-gate stamp keeps the first update's time across later updates")
    func firstUpdateStampIsStable() {
        let coalescer = FetchProgressCoalescer()
        _ = coalescer.shouldForward(bytesTransferred: 1, totalBytes: total)
        let first = coalescer.firstUpdateTime
        _ = coalescer.shouldForward(bytesTransferred: total, totalBytes: total)
        #expect(coalescer.firstUpdateTime == first)
    }
}

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
