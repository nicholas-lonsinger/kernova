import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("SaturatingArithmetic", .caseScoped)
struct SaturatingArithmeticTests {
    @Test("an unsigned sum past the top clamps to max instead of wrapping to a small value")
    func unsignedOverflowClamps() {
        // The wrapping shape this replaces: two halves of 2^64 sum to 0, which
        // then passes every "is this over the cap" comparison.
        #expect((1 << 63 as UInt64) &+ (1 << 63 as UInt64) == 0)
        #expect((1 << 63 as UInt64).saturatingAdding(1 << 63) == .max)
        #expect(UInt64.max.saturatingAdding(1) == .max)
    }
}
