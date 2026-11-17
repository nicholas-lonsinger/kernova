import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMResourceLimits Tests", .caseScoped)
struct VMResourceLimitsTests {
    // MARK: - Framework bounds

    @Test("Byte bounds narrow inward to whole mebibytes")
    func byteBoundsNarrowToWholeMebibytes() {
        let mebibyte: UInt64 = 1 << 20
        let narrowed = VMResourceLimits(
            cpuCount: InclusiveBounds(lower: 1, upper: 8),
            memoryBytes: InclusiveBounds(lower: 128 * mebibyte + 1, upper: 4096 * mebibyte - 1))
        #expect(narrowed.memorySize.lower.bytes == 129 * mebibyte)
        #expect(narrowed.memorySize.upper.bytes == 4095 * mebibyte)
        #expect(narrowed.cpuCount == InclusiveBounds(lower: 1, upper: 8))
    }

    @Test("A bounds check with the bounds out of order refuses every value rather than trapping")
    func invertedBoundsRefuse() {
        let inverted = InclusiveBounds(lower: 10, upper: 2)
        #expect(!inverted.contains(2))
        #expect(!inverted.contains(5))
        #expect(!inverted.contains(10))
        #expect(InclusiveBounds(lower: 2, upper: 10).contains(2))
        #expect(InclusiveBounds(lower: 2, upper: 10).contains(10))
        #expect(!InclusiveBounds(lower: 2, upper: 10).contains(11))
    }
}
