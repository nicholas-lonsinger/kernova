import Foundation
import Testing

@testable import KernovaProtocol

@Suite("ClipboardContent")
struct ClipboardContentTests {
    // MARK: - Digest

    @Test("digest is deterministic for equal content")
    func digestDeterministic() {
        let make = {
            ClipboardContent(representations: [
                .init(uti: "public.png", data: Data([1, 2, 3])),
                .init(uti: "public.utf8-plain-text", data: Data("hi".utf8)),
            ])
        }
        #expect(make().digest == make().digest)
        #expect(make() == make())
    }

    @Test("digest is order-sensitive")
    func digestOrderSensitive() {
        let a = ClipboardContent(representations: [
            .init(uti: "public.png", data: Data([1])),
            .init(uti: "public.tiff", data: Data([2])),
        ])
        let b = ClipboardContent(representations: [
            .init(uti: "public.tiff", data: Data([2])),
            .init(uti: "public.png", data: Data([1])),
        ])
        #expect(a.digest != b.digest)
        #expect(a != b)
    }

    @Test("digest distinguishes byte shifts across the uti/data boundary")
    func digestBoundaryShift() {
        // Same concatenated bytes, different split between uti and data:
        // without length prefixes these would collide.
        let a = ClipboardContent(representations: [.init(uti: "ab", data: Data("c".utf8))])
        let b = ClipboardContent(representations: [.init(uti: "a", data: Data("bc".utf8))])
        #expect(a.digest != b.digest)
    }

    @Test("digest distinguishes representation-boundary shifts")
    func digestRepresentationBoundaryShift() {
        let a = ClipboardContent(representations: [
            .init(uti: "x", data: Data([1, 2])),
            .init(uti: "y", data: Data([3])),
        ])
        let b = ClipboardContent(representations: [
            .init(uti: "x", data: Data([1])),
            .init(uti: "y", data: Data([2, 3])),
        ])
        #expect(a.digest != b.digest)
    }

    // MARK: - Text

    @Test("empty string normalizes to .empty")
    func emptyStringNormalizes() {
        let content = ClipboardContent(text: "")
        #expect(content.isEmpty)
        #expect(content == .empty)
        #expect(content.representations.isEmpty)
    }

    @Test("text init produces a single UTF-8 representation")
    func textInit() {
        let content = ClipboardContent(text: "héllo")
        #expect(content.representations.count == 1)
        #expect(content.representations.first?.uti == ClipboardContent.utf8TextUTI)
        #expect(content.text == "héllo")
        #expect(!content.isEmpty)
    }

    @Test("text reads the first UTF-8 plain-text representation only")
    func textPicksUTF8Rep() {
        let content = ClipboardContent(representations: [
            .init(uti: "public.rtf", data: Data("{\\rtf1}".utf8)),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("shadowed".utf8)),
        ])
        #expect(content.text == "plain")
    }

    @Test("text is nil without a UTF-8 representation or with invalid bytes")
    func textNilCases() {
        let imageOnly = ClipboardContent(representations: [
            .init(uti: "public.png", data: Data([0x89, 0x50]))
        ])
        #expect(imageOnly.text == nil)

        let invalid = ClipboardContent(representations: [
            .init(uti: ClipboardContent.utf8TextUTI, data: Data([0xFF, 0xFE, 0xFD]))
        ])
        #expect(invalid.text == nil)
    }

    @Test("totalByteCount sums all representations")
    func totalByteCount() {
        let content = ClipboardContent(representations: [
            .init(uti: "a", data: Data(count: 10)),
            .init(uti: "b", data: Data(count: 32)),
        ])
        #expect(content.totalByteCount == 42)
    }

    // MARK: - Proto bridging

    @Test("proto round-trip preserves order, UTIs, and bytes")
    func protoRoundTrip() throws {
        let original = ClipboardContent(representations: [
            .init(uti: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("hello".utf8)),
            .init(uti: "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn", data: Data([7])),
        ])

        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardData = Kernova_V1_ClipboardData.with {
            $0.generation = 3
            $0.representations = original.protoRepresentations
        }

        let bytes = try frame.serializedData()
        let decoded = try Frame(serializedBytes: bytes)
        let roundTripped = ClipboardContent(
            protoRepresentations: decoded.clipboardData.representations
        )

        #expect(roundTripped == original)
        #expect(roundTripped.representations.map(\.uti) == original.representations.map(\.uti))
        #expect(roundTripped.representations.map(\.data) == original.representations.map(\.data))
    }

    @Test("ClipboardData at the policy's total cap encodes under the frame limit")
    func policyCapFitsFrameLimit() throws {
        // One frame carries every representation of a generation; the
        // policy's total cap must clear VsockFrame.maxPayloadSize with the
        // protobuf envelope included. Validates the headroom math.
        let half = ClipboardSnapshotPolicy.maxTotalByteCount / 2
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardData = Kernova_V1_ClipboardData.with {
            $0.generation = UInt64.max
            $0.representations = [
                Kernova_V1_ClipboardRepresentation.with {
                    $0.uti = "public.tiff"
                    $0.data = Data(count: half)
                },
                Kernova_V1_ClipboardRepresentation.with {
                    $0.uti = "public.png"
                    $0.data = Data(count: ClipboardSnapshotPolicy.maxTotalByteCount - half)
                },
            ]
        }

        let payload = try frame.serializedData()
        #expect(payload.count <= VsockFrame.maxPayloadSize)
        #expect(throws: Never.self) { try VsockFrame.encode(payload) }
    }
}

@Suite("ClipboardSnapshotPolicy")
struct ClipboardSnapshotPolicyTests {
    @Test("transient marker types are skipped")
    func transientMarkersSkipped() {
        let outcome = ClipboardSnapshotPolicy.evaluate([
            (uti: "org.nspasteboard.TransientType", data: Data([1])),
            (uti: "org.nspasteboard.ConcealedType", data: Data([1])),
            (uti: ClipboardContent.utf8TextUTI, data: Data("keep".utf8)),
        ])
        #expect(outcome.content.representations.map(\.uti) == [ClipboardContent.utf8TextUTI])
        #expect(
            outcome.skipped == [
                .init(uti: "org.nspasteboard.TransientType", reason: .transientMarkerType),
                .init(uti: "org.nspasteboard.ConcealedType", reason: .transientMarkerType),
            ])
    }

    @Test(
        "file reference types are skipped",
        arguments: [
            "public.file-url",
            "com.apple.pasteboard.promised-file-url",
            "com.apple.pasteboard.promised-file-content-type",
            "com.apple.NSFilePromiseProvider",
            "NSFilenamesPboardType",
        ])
    func fileReferenceTypesSkipped(uti: String) {
        #expect(ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: uti))
        let outcome = ClipboardSnapshotPolicy.evaluate([(uti: uti, data: Data([1]))])
        #expect(outcome.content.isEmpty)
        #expect(outcome.skipped == [.init(uti: uti, reason: .fileReferenceType)])
    }

    @Test("dynamic UTIs are kept")
    func dynamicUTIsKept() {
        let dyn = "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn"
        #expect(!ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: dyn))
        let outcome = ClipboardSnapshotPolicy.evaluate([(uti: dyn, data: Data([1]))])
        #expect(outcome.content.representations.map(\.uti) == [dyn])
        #expect(outcome.skipped.isEmpty)
    }

    @Test("zero-byte representations are skipped")
    func zeroByteSkipped() {
        let outcome = ClipboardSnapshotPolicy.evaluate([
            (uti: "public.png", data: Data()),
            (uti: ClipboardContent.utf8TextUTI, data: Data("x".utf8)),
        ])
        #expect(outcome.content.representations.map(\.uti) == [ClipboardContent.utf8TextUTI])
        #expect(outcome.skipped == [.init(uti: "public.png", reason: .emptyData)])
    }

    @Test("oversized representation is dropped while siblings survive")
    func oversizedDropped() {
        let oversize = ClipboardSnapshotPolicy.maxRepresentationByteCount + 1
        let outcome = ClipboardSnapshotPolicy.evaluate([
            (uti: "public.tiff", data: Data(count: oversize)),
            (uti: "public.png", data: Data(count: 1024)),
        ])
        #expect(outcome.content.representations.map(\.uti) == ["public.png"])
        #expect(
            outcome.skipped == [
                .init(uti: "public.tiff", reason: .oversized(byteCount: oversize))
            ])
    }

    @Test("total budget is enforced greedily in input order")
    func totalBudgetGreedy() {
        let big = ClipboardSnapshotPolicy.maxRepresentationByteCount  // 10 MiB, fits alone
        let medium = ClipboardSnapshotPolicy.maxTotalByteCount - big + 1  // tips the total
        let outcome = ClipboardSnapshotPolicy.evaluate([
            (uti: "public.rtf", data: Data(count: big)),
            (uti: "public.tiff", data: Data(count: medium)),
            (uti: ClipboardContent.utf8TextUTI, data: Data("still fits".utf8)),
        ])
        // The medium rep exceeds the remaining budget; the small text rep
        // after it still fits.
        #expect(
            outcome.content.representations.map(\.uti) == [
                "public.rtf", ClipboardContent.utf8TextUTI,
            ])
        #expect(
            outcome.skipped == [
                .init(
                    uti: "public.tiff",
                    reason: .totalBudgetExceeded(
                        byteCount: medium,
                        remaining: ClipboardSnapshotPolicy.maxTotalByteCount - big
                    ))
            ])
    }

    @Test("all-skipped input yields empty content with populated skip report")
    func allSkippedNeverSilent() {
        let outcome = ClipboardSnapshotPolicy.evaluate([
            (uti: "org.nspasteboard.AutoGeneratedType", data: Data([1])),
            (uti: "public.file-url", data: Data([2])),
        ])
        #expect(outcome.content.isEmpty)
        #expect(outcome.skipped.count == 2)
    }

    @Test("empty input yields empty content and no skips")
    func emptyInput() {
        let outcome = ClipboardSnapshotPolicy.evaluate([])
        #expect(outcome.content.isEmpty)
        #expect(outcome.skipped.isEmpty)
    }
}
