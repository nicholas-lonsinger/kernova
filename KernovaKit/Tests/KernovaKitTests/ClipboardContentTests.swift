import Foundation
import Testing

@testable import KernovaKit

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

    @Test("filename is folded into the digest (distinguishes same-bytes files by name)")
    func filenameInDigest() {
        // Required once a payload can carry several files: two file payloads that
        // share bytes+UTI but differ only by name must hash differently, or a
        // legitimate [a,b] → [a,c] change (b/c byte-identical) would be silently
        // echo-suppressed by the digest guards.
        let withName = ClipboardContent(representations: [
            .init(uti: "public.png", data: Data([1, 2, 3]), filename: "photo.png")
        ])
        let withoutName = ClipboardContent(representations: [
            .init(uti: "public.png", data: Data([1, 2, 3]))
        ])
        #expect(withName.digest != withoutName.digest)

        let differentName = ClipboardContent(representations: [
            .init(uti: "public.png", data: Data([1, 2, 3]), filename: "other.png")
        ])
        #expect(withName.digest != differentName.digest)

        // Same name round-trips to the same digest, so cross-process echo
        // suppression is preserved.
        let sameName = ClipboardContent(representations: [
            .init(uti: "public.png", data: Data([1, 2, 3]), filename: "photo.png")
        ])
        #expect(withName.digest == sameName.digest)
    }

    @Test("two file reps differing only by filename produce different digests")
    func multiFileNameSensitivity() {
        // The multi-file echo-suppression scenario: [a.bin, b.bin] vs
        // [a.bin, c.bin] where b and c are byte-identical (same sha256). Only the
        // second name differs, and that must change the content digest.
        let sha = Data(repeating: 0xAB, count: 32)
        func content(secondName: String) -> ClipboardContent {
            ClipboardContent(representations: [
                .init(
                    uti: "public.data", fileURL: URL(fileURLWithPath: "/tmp/a"),
                    byteCount: 8, sha256: sha, filename: "a.bin"),
                .init(
                    uti: "public.data", fileURL: URL(fileURLWithPath: "/tmp/x"),
                    byteCount: 8, sha256: sha, filename: secondName),
            ])
        }
        #expect(content(secondName: "b.bin").digest != content(secondName: "c.bin").digest)
    }

    @Test("isDirectory is excluded from the digest")
    func isDirectoryDigestInvisible() {
        // The archive's SHA-256 plus the folded folder name already identify a
        // directory rep, and the receiver re-derives the flag from the offer, so
        // hashing it would only risk a host/guest asymmetry. Two reps differing
        // only by isDirectory must hash identically.
        let sha = Data(repeating: 0xCD, count: 32)
        func content(isDirectory: Bool) -> ClipboardContent {
            ClipboardContent(representations: [
                .init(
                    uti: "public.folder", fileURL: URL(fileURLWithPath: "/tmp/a.aar"),
                    byteCount: 16, sha256: sha, filename: "MyFolder", isDirectory: isDirectory)
            ])
        }
        #expect(content(isDirectory: true).digest == content(isDirectory: false).digest)
        // Sanity: the flag itself round-trips on the representation.
        #expect(content(isDirectory: true).representations[0].isDirectory)
    }

    // MARK: - .pendingRemote (lazy-receive placeholder) digest

    @Test(".pendingRemote digest is deterministic for equal (uti, byteCount)")
    func pendingRemoteDigestDeterministic() {
        let make = {
            ClipboardContent(representations: [
                .init(pendingRemoteUTI: "public.png", byteCount: 4096, filename: "photo.png")
            ])
        }
        #expect(make().digest == make().digest)
        #expect(make() == make())

        // Filename is folded into the digest here too, so the same placeholder
        // with no name is a different digest (uniform with the materialized form).
        let withoutName = ClipboardContent(representations: [
            .init(pendingRemoteUTI: "public.png", byteCount: 4096)
        ])
        #expect(make().digest != withoutName.digest)

        // A different advertised byteCount changes the placeholder's identity.
        let differentSize = ClipboardContent(representations: [
            .init(pendingRemoteUTI: "public.png", byteCount: 4097)
        ])
        #expect(make().digest != differentSize.digest)
    }

    @Test(".pendingRemote is never digest-equal to the same rep materialized as .inMemory")
    func pendingRemoteDistinctFromInMemory() {
        // A 3-byte inline payload under the same UTI must not alias the
        // metadata-only placeholder advertising 3 bytes — the domain tag (3 vs
        // the inline tag 0) keeps them apart so a pulled rep is a real change.
        let bytes = Data([1, 2, 3])
        let placeholder = ClipboardContent(representations: [
            .init(pendingRemoteUTI: "public.png", byteCount: bytes.count)
        ])
        let materialized = ClipboardContent(representations: [
            .init(uti: "public.png", data: bytes)
        ])
        #expect(placeholder.digest != materialized.digest)
    }

    @Test(".pendingRemote is never digest-equal to the same rep materialized as .file")
    func pendingRemoteDistinctFromFile() {
        let sha = Data(repeating: 0xAB, count: 32)
        let placeholder = ClipboardContent(representations: [
            .init(pendingRemoteUTI: "public.data", byteCount: 1024, filename: "x.bin")
        ])
        let materializedFile = ClipboardContent(representations: [
            .init(
                uti: "public.data", fileURL: URL(fileURLWithPath: "/tmp/x.bin"),
                byteCount: 1024, sha256: sha, filename: "x.bin")
        ])
        #expect(placeholder.digest != materializedFile.digest)
    }

    @Test(".pendingRemote is distinct from a .file placeholder with no streamed sha256 (tag 2 vs 3)")
    func pendingRemoteDistinctFromUnhashedFilePlaceholder() {
        // A `.file` rep whose bytes haven't streamed yet folds in only its byte
        // count under tag 2; a `.pendingRemote` rep folds in its byte count under
        // tag 3. Same UTI and byte count, but the domain tags keep them apart.
        let pendingRemote = ClipboardContent(representations: [
            .init(pendingRemoteUTI: "public.data", byteCount: 1024)
        ])
        let unhashedFile = ClipboardContent(representations: [
            .init(
                uti: "public.data", fileURL: URL(fileURLWithPath: "/tmp/x.bin"),
                byteCount: 1024, sha256: nil, filename: "x.bin")
        ])
        #expect(pendingRemote.digest != unhashedFile.digest)
    }

    @Test(".pendingRemote accessors expose metadata only — no resident bytes or file URL")
    func pendingRemoteAccessors() {
        let rep = ClipboardContent.Representation(
            pendingRemoteUTI: "public.png", byteCount: 9_000_000_000, filename: "huge.png")
        #expect(rep.isPendingRemote)
        #expect(rep.byteCount == 9_000_000_000)  // advertised, never loaded
        #expect(rep.inMemoryData == nil)
        #expect(rep.fileURL == nil)
        #expect(rep.uti == "public.png")
        #expect(rep.filename == "huge.png")
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
                byteCount: 1024, sha256: sha, filename: "data.bin")
        ])
        let b = ClipboardContent(representations: [
            .init(
                uti: "public.data", fileURL: URL(fileURLWithPath: "/var/guest.bin"),
                byteCount: 1024, sha256: sha, filename: "data.bin")
        ])
        // Same bytes (same sha256) and same suggested name, different *path* →
        // same digest: the host and guest temp paths differ but are never hashed.
        #expect(a.digest == b.digest)

        let differentBytes = ClipboardContent(representations: [
            .init(
                uti: "public.data", fileURL: URL(fileURLWithPath: "/tmp/host.bin"),
                byteCount: 1024, sha256: Data(repeating: 0xCD, count: 32), filename: "data.bin")
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

    @Test("makeOffActor(text:) matches init(text:) for empty, small, and large text")
    func makeOffActorTextMatchesSyncInit() async {
        // The editor commit path relies on these being identical so the off-actor
        // commit and the synchronous flush produce the same content/digest.
        let large = String(repeating: "swift clipboard ", count: 4096)  // ~64 KiB
        for text in ["", "hello", large] {
            let sync = ClipboardContent(text: text)
            let offMain = await ClipboardContent.makeOffActor(text: text)
            #expect(offMain == sync)  // digest-based equality
            #expect(offMain.digest == sync.digest)
            #expect(offMain.representations.map(\.inMemoryData) == sync.representations.map(\.inMemoryData))
        }
        // The empty string normalizes to `.empty`, identically to init(text:).
        #expect(await ClipboardContent.makeOffActor(text: "") == .empty)
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

    // MARK: - Snapshot disposition

    @Test("a transient marker suppresses the whole snapshot")
    func transientSuppressesSnapshot() {
        #expect(
            ClipboardSnapshotPolicy.disposition(forTypes: [
                "org.nspasteboard.TransientType", ClipboardContent.utf8TextUTI,
            ]) == .suppress(.transientSnapshot))
    }

    @Test("an auto-generated marker suppresses the whole snapshot")
    func autoGeneratedSuppressesSnapshot() {
        #expect(
            ClipboardSnapshotPolicy.disposition(forTypes: [
                "org.nspasteboard.AutoGeneratedType", ClipboardContent.utf8TextUTI,
            ]) == .suppress(.autoGeneratedSnapshot))
    }

    @Test("a concealed marker conceals but does not suppress")
    func concealedConcealsSnapshot() {
        #expect(
            ClipboardSnapshotPolicy.disposition(forTypes: [
                "org.nspasteboard.ConcealedType", ClipboardContent.utf8TextUTI,
            ]) == .conceal)
    }

    @Test("a snapshot with no markers is allowed")
    func plainSnapshotAllowed() {
        #expect(
            ClipboardSnapshotPolicy.disposition(forTypes: [
                ClipboardContent.utf8TextUTI, "public.png",
            ]) == .allow)
    }

    @Test("transient takes precedence over a coexisting concealed marker")
    func transientBeatsConcealed() {
        #expect(
            ClipboardSnapshotPolicy.disposition(forTypes: [
                "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
            ]) == .suppress(.transientSnapshot))
    }
}

@Suite("ClipboardContent.isConcealed")
struct ClipboardContentConcealedTests {
    @Test("defaults to false")
    func defaultsFalse() {
        #expect(!ClipboardContent(text: "hi").isConcealed)
        #expect(!ClipboardContent(representations: []).isConcealed)
    }

    @Test("round-trips through the representation initializer")
    func roundTrips() {
        let content = ClipboardContent(
            representations: [.init(uti: ClipboardContent.utf8TextUTI, data: Data("secret".utf8))],
            isConcealed: true)
        #expect(content.isConcealed)
    }

    @Test("is excluded from the digest, so it does not affect equality")
    func excludedFromDigest() {
        let reps = [ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: Data("pw".utf8))]
        let plain = ClipboardContent(representations: reps, isConcealed: false)
        let concealed = ClipboardContent(representations: reps, isConcealed: true)
        // Equality is digest-based; concealment is display metadata, not identity,
        // so echo suppression must treat the two as the same content.
        #expect(plain == concealed)
        #expect(plain.digest == concealed.digest)
    }

    @Test("withConcealed sets the flag and reuses the digest (no re-hash)")
    func withConcealedReusesDigest() {
        let reps = [ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: Data("pw".utf8))]
        let plain = ClipboardContent(representations: reps, isConcealed: false)
        let concealed = plain.withConcealed(true)
        #expect(concealed.isConcealed)
        // The digest must be byte-identical to the unconcealed content's — that is
        // the whole point: the re-stamp avoids a second SHA-256, and the flag is
        // excluded from the digest so echo suppression stays unaffected.
        #expect(concealed.digest == plain.digest)
        #expect(concealed == plain)
        // Matches the digest a from-scratch concealed build would produce.
        #expect(concealed.digest == ClipboardContent(representations: reps, isConcealed: true).digest)
    }

    @Test("withConcealed returns self unchanged when the flag already matches")
    func withConcealedNoOpWhenUnchanged() {
        let reps = [ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: Data("pw".utf8))]
        let plain = ClipboardContent(representations: reps, isConcealed: false)
        #expect(plain.withConcealed(false) == plain)
        let concealed = ClipboardContent(representations: reps, isConcealed: true)
        #expect(concealed.withConcealed(true).isConcealed)
        #expect(concealed.withConcealed(true).digest == concealed.digest)
    }

    @Test("withConcealed clears the flag and reuses the digest")
    func withConcealedClearsTheFlag() {
        let reps = [ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: Data("pw".utf8))]
        let concealed = ClipboardContent(representations: reps, isConcealed: true)
        let revealed = concealed.withConcealed(false)
        #expect(!revealed.isConcealed)
        // Clearing reuses the digest too (the flag is excluded), so the revealed
        // copy stays digest-equal to the concealed original and to a from-scratch
        // unconcealed build.
        #expect(revealed.digest == concealed.digest)
        #expect(revealed == ClipboardContent(representations: reps, isConcealed: false))
    }
}
