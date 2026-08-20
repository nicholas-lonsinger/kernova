import Testing

@testable import KernovaKit

@Suite("ClipboardOfferBounds", .admissionGated)
struct ClipboardOfferBoundsTests {
    private func rep(
        uti: String = "public.data", byteCount: UInt64, filename: String = "a.bin"
    ) -> Kernova_V1_ClipboardRepresentationInfo {
        Kernova_V1_ClipboardRepresentationInfo.with {
            $0.uti = uti
            $0.byteCount = byteCount
            $0.filename = filename
        }
    }

    @Test("a plausible offer passes through untouched")
    func plausibleOfferUnchanged() {
        let reps = [rep(byteCount: 10), rep(byteCount: 5_000_000_000)]
        let bounded = ClipboardOfferBounds.bounded(reps)
        #expect(bounded.reps == reps)
        #expect(bounded.truncatedFrom == nil)
        #expect(bounded.clampedCount == 0)
    }

    @Test("a declared byte count past the ceiling is clamped, not wrapped or trusted")
    func absurdByteCountClamped() {
        let bounded = ClipboardOfferBounds.bounded([
            rep(byteCount: .max), rep(byteCount: 1), rep(byteCount: 1 << 63),
        ])
        #expect(
            bounded.reps.map(\.byteCount) == [
                ClipboardOfferBounds.maxDeclaredByteCount, 1,
                ClipboardOfferBounds.maxDeclaredByteCount,
            ])
        #expect(bounded.clampedCount == 2)
    }

    @Test("a full offer of clamped sizes still sums inside Int64")
    func clampedOfferSumsInRange() {
        let maxTotal =
            ClipboardOfferBounds.maxDeclaredByteCount
            * UInt64(ClipboardContent.maxOfferableRepresentations)
        #expect(maxTotal < UInt64(Int64.max))
    }

    @Test("a rep count past the offer limit is truncated from the tail, keeping wire indices")
    func repCountTruncated() {
        let overLimit = ClipboardContent.maxOfferableRepresentations + 3
        let reps = (0..<overLimit).map { rep(byteCount: UInt64($0 + 1), filename: "f\($0).bin") }
        let bounded = ClipboardOfferBounds.bounded(reps)
        #expect(bounded.reps.count == ClipboardContent.maxOfferableRepresentations)
        #expect(bounded.truncatedFrom == overLimit)
        // Head-preserving: rep 0 is still rep 0, so a transfer id built from an
        // index still addresses the rep the peer offered at it.
        #expect(bounded.reps.first == reps.first)
        #expect(bounded.reps.last == reps[ClipboardContent.maxOfferableRepresentations - 1])
    }
}
