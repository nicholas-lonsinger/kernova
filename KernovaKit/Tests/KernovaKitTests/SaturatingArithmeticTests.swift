import Testing

@testable import KernovaKit

@Suite("SaturatingArithmetic", .admissionGated)
struct SaturatingArithmeticTests {
    @Test("a sum that fits is the ordinary sum")
    func inRangeSum() {
        #expect((2 as UInt64).saturatingAdding(3) == 5)
        #expect(Int.max.saturatingAdding(0) == .max)
        #expect((-4 as Int).saturatingAdding(1) == -3)
    }

    @Test("an unsigned sum past the top clamps to max instead of wrapping to a small value")
    func unsignedOverflowClamps() {
        // The wrapping shape this replaces: two halves of 2^64 sum to 0, which
        // then passes every "is this over the cap" comparison.
        #expect((1 << 63 as UInt64) &+ (1 << 63 as UInt64) == 0)
        #expect((1 << 63 as UInt64).saturatingAdding(1 << 63) == .max)
        #expect(UInt64.max.saturatingAdding(1) == .max)
    }

    @Test("a signed sum clamps at the bound it would pass, in both directions")
    func signedOverflowClamps() {
        #expect(Int.max.saturatingAdding(1) == .max)
        #expect(Int.max.saturatingAdding(.max) == .max)
        #expect(Int.min.saturatingAdding(-1) == .min)
    }
}
