import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ClipboardContent", .caseScoped)
struct ClipboardContentTests {
    // MARK: - Digest

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

    // MARK: - Text

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

    @Test("totalByteCount saturates on an absurd sum rather than trapping")
    func totalByteCountSaturates() {
        // Placeholder reps carry peer-declared sizes, so the sum is not bounded
        // by anything local.
        let content = ClipboardContent(representations: [
            .init(pendingRemoteUTI: "a", byteCount: .max, filename: "a.bin"),
            .init(pendingRemoteUTI: "b", byteCount: .max, filename: "b.bin"),
        ])
        #expect(content.totalByteCount == .max)
    }

    @Test("makeOffActor(text:) holds one UTF-8 representation of the text, the empty string none")
    func makeOffActorText() async {
        let large = String(repeating: "swift clipboard ", count: 4096)  // ~64 KiB
        for text in ["hello", large] {
            let sync = ClipboardContent(representations: [
                .init(uti: ClipboardContent.utf8TextUTI, data: Data(text.utf8))
            ])
            let offMain = await ClipboardContent.makeOffActor(text: text)
            #expect(offMain == sync)  // digest-based equality
            #expect(offMain.digest == sync.digest)
            #expect(offMain.representations.map(\.inMemoryData) == sync.representations.map(\.inMemoryData))
        }
        #expect(await ClipboardContent.makeOffActor(text: "") == .empty)
    }
}

@Suite("ClipboardSnapshotPolicy", .caseScoped)
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

    @Test("zero-byte representations are skipped")
    func zeroByteSkipped() {
        let outcome = ClipboardSnapshotPolicy.evaluate([
            (uti: "public.png", data: Data()),
            (uti: ClipboardContent.utf8TextUTI, data: Data("x".utf8)),
        ])
        #expect(outcome.content.representations.map(\.uti) == [ClipboardContent.utf8TextUTI])
        #expect(outcome.skipped == [.init(uti: "public.png", reason: .emptyData)])
    }

    // MARK: - Snapshot disposition

    @Test("a snapshot with no markers is allowed")
    func plainSnapshotAllowed() {
        #expect(
            ClipboardSnapshotPolicy.disposition(forTypes: [
                ClipboardContent.utf8TextUTI, "public.png",
            ]) == .allow)
    }
}

@Suite("ClipboardContent.isConcealed", .caseScoped)
struct ClipboardContentConcealedTests {
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
}
