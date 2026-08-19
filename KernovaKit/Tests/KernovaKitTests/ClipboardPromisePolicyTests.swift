import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for the receive-side gate both peers apply to an offer's
/// representations before a byte of it crosses.
@Suite("ClipboardPromisePolicy", .admissionGated)
struct ClipboardPromisePolicyTests {
    private func info(
        uti: String = ClipboardContent.utf8TextUTI, byteCount: UInt64 = 8, filename: String = "",
        isInline: Bool = true
    ) -> Kernova_V1_ClipboardRepresentationInfo {
        Kernova_V1_ClipboardRepresentationInfo.with {
            $0.uti = uti
            $0.byteCount = byteCount
            $0.filename = filename
            $0.isInline = isInline
        }
    }

    // MARK: - keeps

    @Test("an ordinary inline representation is kept")
    func keepsInlineRepresentation() {
        #expect(ClipboardPromisePolicy.keeps(info()))
    }

    @Test("an identity-skipped type is never kept")
    func dropsIdentitySkippedTypes() {
        #expect(!ClipboardPromisePolicy.keeps(info(uti: "public.file-url")))
        #expect(!ClipboardPromisePolicy.keeps(info(uti: ClipboardSnapshotPolicy.concealedMarkerUTI)))
    }

    @Test("an empty payload is kept only when it names a file")
    func keepsEmptyPayloadOnlyWhenNamed() {
        #expect(!ClipboardPromisePolicy.keeps(info(byteCount: 0)))
        #expect(ClipboardPromisePolicy.keeps(info(byteCount: 0, filename: "empty.txt")))
    }

    // MARK: - servesFileURL

    @Test("only a kept representation with a filename serves .fileURL")
    func servesFileURLForNamedKeptReps() {
        #expect(ClipboardPromisePolicy.servesFileURL(info(filename: "photo.png")))
        #expect(!ClipboardPromisePolicy.servesFileURL(info()))
        #expect(
            !ClipboardPromisePolicy.servesFileURL(
                info(uti: "public.file-url", filename: "smuggled.txt")))
    }

    // MARK: - Paste budget

    @Test("the paste-bound total counts only the .fileURL-serving reps")
    func totalsOnlyFileServingReps() {
        let reps = [
            info(byteCount: 100, filename: "a.bin"),
            info(byteCount: 200),
            info(byteCount: 300, filename: "b.bin"),
        ]
        #expect(ClipboardPromisePolicy.pasteBudget(reps, limit: .max).total == 400)
    }

    @Test("the paste-bound total saturates rather than wrapping")
    func totalSaturates() {
        let reps = [
            info(byteCount: .max, filename: "a.bin"),
            info(byteCount: 1, filename: "b.bin"),
        ]
        #expect(ClipboardPromisePolicy.pasteBudget(reps, limit: .max).total == .max)
    }

    @Test("a set exactly at the cap is within budget, one byte over is not")
    func atCapIsWithinBudget() {
        let reps = [info(byteCount: 100, filename: "a.bin")]
        #expect(!ClipboardPromisePolicy.pasteBudget(reps, limit: 100).exceeds)
        #expect(ClipboardPromisePolicy.pasteBudget(reps, limit: 99).exceeds)
        #expect(ClipboardPromisePolicy.pasteBudget(reps, limit: 99).limit == 99)
    }

    // MARK: - descriptors

    @Test("descriptors carry the gate's verdict per representation")
    func descriptorsCarryTheVerdict() {
        let descriptors = ClipboardPromisePolicy.descriptors(for: [
            info(filename: "keep.txt"),
            info(byteCount: 0),
        ])
        #expect(descriptors.count == 2)
        #expect(descriptors[0].isPromisable)
        #expect(descriptors[0].filename == "keep.txt")
        #expect(!descriptors[1].isPromisable)
    }
}
