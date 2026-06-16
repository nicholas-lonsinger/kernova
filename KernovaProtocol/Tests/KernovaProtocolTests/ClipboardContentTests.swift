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

    @Test("filename stays out of the digest (load-bearing for echo suppression)")
    func filenameNotInDigest() {
        let withName = ClipboardContent(representations: [
            .init(uti: "public.png", data: Data([1, 2, 3]), filename: "photo.png")
        ])
        let withoutName = ClipboardContent(representations: [
            .init(uti: "public.png", data: Data([1, 2, 3]))
        ])
        #expect(withName.digest == withoutName.digest)
    }

    // MARK: - Disk-backed (.file) source

    @Test("byteCount and inMemoryData reflect the representation source")
    func sourceAccessors() {
        let inline = ClipboardContent.Representation(uti: "public.png", data: Data([1, 2, 3]))
        #expect(inline.byteCount == 3)
        #expect(inline.inMemoryData == Data([1, 2, 3]))
        #expect(inline.fileURL == nil)

        let url = URL(fileURLWithPath: "/tmp/x.bin")
        let file = ClipboardContent.Representation(
            uti: "public.data", fileURL: url, byteCount: 9_000_000_000, filename: "x.bin")
        #expect(file.byteCount == 9_000_000_000)  // multi-GB without loading
        #expect(file.inMemoryData == nil)
        #expect(file.fileURL == url)
    }

    @Test("a file representation's digest uses its streamed sha256, not its path")
    func fileDigestUsesSha256NotPath() {
        let sha = Data(repeating: 0xAB, count: 32)
        let a = ClipboardContent(representations: [
            .init(
                uti: "public.data", fileURL: URL(fileURLWithPath: "/tmp/host.bin"),
                byteCount: 1024, sha256: sha, filename: "a.bin")
        ])
        let b = ClipboardContent(representations: [
            .init(
                uti: "public.data", fileURL: URL(fileURLWithPath: "/var/guest.bin"),
                byteCount: 1024, sha256: sha, filename: "b.bin")
        ])
        // Same bytes (same sha256), different path/name → same digest.
        #expect(a.digest == b.digest)

        let differentBytes = ClipboardContent(representations: [
            .init(
                uti: "public.data", fileURL: URL(fileURLWithPath: "/tmp/host.bin"),
                byteCount: 1024, sha256: Data(repeating: 0xCD, count: 32), filename: "a.bin")
        ])
        #expect(a.digest != differentBytes.digest)
    }

    @Test("totalByteCount sums file and inline representations without loading")
    func totalByteCountMixed() {
        let content = ClipboardContent(representations: [
            .init(uti: "a", data: Data(count: 10)),
            .init(
                uti: "b", fileURL: URL(fileURLWithPath: "/tmp/x"), byteCount: 5_000_000_000,
                filename: "x"),
        ])
        #expect(content.totalByteCount == 5_000_000_010)
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

    @Test("makeOffActor yields the same digest and representations as the sync init")
    func makeOffActorMatchesSyncInit() async {
        let reps: [ClipboardContent.Representation] = [
            .init(uti: "public.tiff", data: Data(count: 4096), filename: "a.tiff"),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("hello".utf8)),
        ]
        let sync = ClipboardContent(representations: reps)
        let offMain = await ClipboardContent.makeOffActor(representations: reps)

        #expect(offMain.digest == sync.digest)
        #expect(offMain == sync)  // digest-based equality
        #expect(offMain.representations.map(\.uti) == sync.representations.map(\.uti))
        #expect(offMain.representations.map(\.inMemoryData) == sync.representations.map(\.inMemoryData))
        #expect(offMain.representations.map(\.filename) == sync.representations.map(\.filename))
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

    @Test("a representation far larger than the old 104 MiB cap is kept (no size limit)")
    func noSizeCap() {
        // The greedy budget and per-rep cap are gone — streaming bounds size by
        // free disk, not a fixed limit. A 200 MiB inline rep survives evaluate.
        let huge = 200 * 1024 * 1024
        let outcome = ClipboardSnapshotPolicy.evaluate([
            (uti: "public.tiff", data: Data(count: huge)),
            (uti: ClipboardContent.utf8TextUTI, data: Data("also kept".utf8)),
        ])
        #expect(
            outcome.content.representations.map(\.uti) == [
                "public.tiff", ClipboardContent.utf8TextUTI,
            ])
        #expect(outcome.skipped.isEmpty)
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

    @Test("sanitizedForApply strips file references and markers, keeps everything else")
    func sanitizedForApply() {
        let sanitized = ClipboardSnapshotPolicy.sanitizedForApply([
            .init(uti: "public.png", data: Data([1])),
            .init(uti: "public.file-url", data: Data("file:///etc/passwd".utf8)),
            .init(uti: "org.nspasteboard.TransientType", data: Data([1])),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("text".utf8)),
        ])
        #expect(sanitized.map(\.uti) == ["public.png", ClipboardContent.utf8TextUTI])
    }

    @Test("sanitizedForApply keeps an arbitrarily large representation (no size cap)")
    func sanitizedForApplyNoSizeCap() {
        let sanitized = ClipboardSnapshotPolicy.sanitizedForApply([
            .init(uti: "public.tiff", data: Data(count: 200 * 1024 * 1024)),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("small".utf8)),
        ])
        #expect(sanitized.map(\.uti) == ["public.tiff", ClipboardContent.utf8TextUTI])
    }

    @Test("sanitizedForApply drops empty reps (symmetric with evaluate)")
    func sanitizedForApplyDropsEmptyData() {
        let sanitized = ClipboardSnapshotPolicy.sanitizedForApply([
            .init(uti: "public.png", data: Data()),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("keep".utf8)),
        ])
        #expect(sanitized.map(\.uti) == [ClipboardContent.utf8TextUTI])
    }
}
