import AppleArchive
import Darwin
import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaKit

/// Collects every encoded byte, for the cases that drive the codec rather than
/// the whole-archive helpers above it.
private final class ArchiveBytesSink: ClipboardSequentialArchiveStream, @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()

    var bytes: Data { lock.withLock { collected } }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        lock.withLock { collected.append(contentsOf: buffer) }
        return buffer.count
    }
}

/// Hands one buffer's bytes to the decoder in reads, for the cases that need the
/// codec's own `onOutputAdvanced` guard.
private final class ArchiveBytesSource: ClipboardSequentialArchiveStream, @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Data
    private var offset = 0

    init(bytes: Data) {
        self.bytes = bytes
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let destination = buffer.baseAddress else { return 0 }
        return lock.withLock {
            let take = min(buffer.count, bytes.count - offset)
            guard take > 0 else { return 0 }
            let start = bytes.index(bytes.startIndex, offsetBy: offset)
            bytes[start..<bytes.index(start, offsetBy: take)].withUnsafeBytes { raw in
                guard let source = raw.baseAddress else { return }
                destination.copyMemory(from: source, byteCount: take)
            }
            offset += take
            return take
        }
    }
}

/// The archive codec on its own: a source — a folder, one file, or resident
/// bytes — encoded whole by ``ClipboardArchive/archiveBytes(of:)`` and unpacked
/// by ``ClipboardArchive/extract(_:into:)``, which together pin what an archived
/// transfer preserves and what it deliberately drops. The connection that
/// carries the archive is `ClipboardTransferStreamTests`.
@Suite("ClipboardArchiveCodec")
struct ClipboardArchiveStreamTests {
    /// A unique scratch directory removed when the test ends.
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An empty directory to extract into — what `extract` requires.
    private func makeDestination(in scratch: URL, named name: String = "out") throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Encodes `source` whole and unpacks it into a fresh directory under
    /// `scratch`, which it returns — the round trip every fidelity case asserts
    /// on.
    @discardableResult
    private func roundTrip(_ source: ClipboardArchiveSource, in scratch: URL) throws -> URL {
        let destination = try makeDestination(in: scratch)
        try ClipboardArchive.extract(
            try ClipboardArchive.archiveBytes(of: source), into: destination)
        return destination
    }

    /// How many bytes of `url` landed, or `0` when nothing did.
    private func landedByteCount(at url: URL) -> Int {
        (try? Data(contentsOf: url))?.count ?? 0
    }

    // MARK: - Folder fidelity

    @Test("a nested tree, its contents, an empty directory and the exec bit round-trip")
    func roundTripFidelity() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("a/b/c", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try "top".write(
            to: source.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try "deep".write(
            to: nested.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)
        try fm.createDirectory(
            at: source.appendingPathComponent("emptydir", isDirectory: true),
            withIntermediateDirectories: true)
        let exe = source.appendingPathComponent("run.sh")
        try "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let dest = try roundTrip(.directory(source), in: scratch)

        #expect(
            try String(contentsOf: dest.appendingPathComponent("top.txt"), encoding: .utf8) == "top")
        #expect(
            try String(contentsOf: dest.appendingPathComponent("a/b/c/deep.txt"), encoding: .utf8)
                == "deep")
        var isDir: ObjCBool = false
        #expect(
            fm.fileExists(atPath: dest.appendingPathComponent("emptydir").path, isDirectory: &isDir)
                && isDir.boolValue)
        let perms =
            (try fm.attributesOfItem(atPath: dest.appendingPathComponent("run.sh").path)[
                .posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms & 0o111 != 0)
        // The tree and nothing beside it: the extract leaves no working file of
        // its own next to what it unpacked.
        #expect(try fm.contentsOfDirectory(atPath: scratch.path).sorted() == ["out", "source"])
    }

    @Test("a symlink is preserved, not followed")
    func symlinkPreserved() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "target".write(
            to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            atPath: source.appendingPathComponent("link.txt").path, withDestinationPath: "file.txt")

        let dest = try roundTrip(.directory(source), in: scratch)

        let linkPath = dest.appendingPathComponent("link.txt").path
        let attrs = try fm.attributesOfItem(atPath: linkPath)
        #expect((attrs[.type] as? FileAttributeType) == .typeSymbolicLink)
        #expect(try fm.destinationOfSymbolicLink(atPath: linkPath) == "file.txt")
    }

    @Test("a package-shaped directory (.rtfd) round-trips as a directory")
    func bundleRoundTrips() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        let rtfd = source.appendingPathComponent("note.rtfd", isDirectory: true)
        try fm.createDirectory(at: rtfd, withIntermediateDirectories: true)
        try "{\\rtf1}".write(
            to: rtfd.appendingPathComponent("TXT.rtf"), atomically: true, encoding: .utf8)

        let dest = try roundTrip(.directory(source), in: scratch)

        #expect(
            try String(
                contentsOf: dest.appendingPathComponent("note.rtfd/TXT.rtf"), encoding: .utf8)
                == "{\\rtf1}")
    }

    @Test("unicode names survive the round trip")
    func unicodeNamesRoundTrip() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        let folder = source.appendingPathComponent("Ünïcødé 🎉", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "ok".write(
            to: folder.appendingPathComponent("naïve — файл.txt"), atomically: true, encoding: .utf8)

        let dest = try roundTrip(.directory(source), in: scratch)

        #expect(
            try String(
                contentsOf: dest.appendingPathComponent("Ünïcødé 🎉/naïve — файл.txt"),
                encoding: .utf8) == "ok")
    }

    @Test("an empty directory encodes real bytes and extracts to an empty tree")
    func emptyDirectoryRoundTrips() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)

        // Archive-header bytes, so an encoded folder is never legitimately
        // zero-length whatever the tree inside it holds.
        let bytes = try ClipboardArchive.archiveBytes(of: .directory(source))
        #expect(!bytes.isEmpty)
        let dest = try makeDestination(in: scratch)
        try ClipboardArchive.extract(bytes, into: dest)
        #expect(try fm.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    @Test("a tree carrying no file bytes still round-trips")
    func byteFreeTreeRoundTrips() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("scaffold", isDirectory: true)
        try fm.createDirectory(
            at: source.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent(".keep"))
        try Data().write(to: source.appendingPathComponent("sub/.keep"))
        #expect(ClipboardArchive.estimatedByteCount(at: source) == 0)

        let dest = try roundTrip(.directory(source), in: scratch)
        #expect(fm.fileExists(atPath: dest.appendingPathComponent(".keep").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("sub/.keep").path))
    }

    @Test("a locked file inside a folder extracts unlocked, so the whole tree can be swept")
    func lockedFileInsideAFolderExtractsUnlocked() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let locked = nested.appendingPathComponent("locked.bin")
        try Data(repeating: 0x2A, count: 1024).write(to: locked)
        try "plain".write(
            to: source.appendingPathComponent("plain.txt"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: locked.path) }

        let dest = try roundTrip(.directory(source), in: scratch)

        let entry = dest.appendingPathComponent("sub/locked.bin")
        let immutable = try fm.attributesOfItem(atPath: entry.path)[.immutable] as? Bool
        #expect(immutable != true)
        #expect(try Data(contentsOf: entry) == Data(repeating: 0x2A, count: 1024))
        // The proof that matters: a locked entry blocks `unlink` on itself and on
        // every directory above it, so an undeleted tree here is a staging
        // generation — and the shared staging parent behind it — that no sweep
        // can ever reclaim.
        try fm.removeItem(at: dest)
        #expect(!fm.fileExists(atPath: dest.path))
    }

    @Test("a locked directory extracts unlocked, so its children can still be swept")
    func lockedDirectoryExtractsUnlocked() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        let locked = source.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try "inside".write(
            to: locked.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
        // Locked last: an immutable directory takes no new entries.
        try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: locked.path) }

        let dest = try roundTrip(.directory(source), in: scratch)

        // The peer authors every entry's flags, and a locked *directory* is the
        // damaging shape: it blocks `unlink` of everything inside it, so one in
        // a staged tree is what makes the shared staging parent's reclaim fail
        // for good.
        let extracted = dest.appendingPathComponent("locked")
        let immutable = try fm.attributesOfItem(atPath: extracted.path)[.immutable] as? Bool
        #expect(immutable != true)
        #expect(
            try String(contentsOf: extracted.appendingPathComponent("child.txt"), encoding: .utf8)
                == "inside")
        try fm.removeItem(at: dest)
        #expect(!fm.fileExists(atPath: dest.path))
    }

    // MARK: - One-entry sources

    @Test("a file source round-trips byte-identically under its entry name, with mode and times")
    func fileSourceRoundTrips() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let file = scratch.appendingPathComponent("payload.bin")
        let payload = patternedBytes(count: 256 * 1024, multiplier: 7, offset: 3)
        try payload.write(to: file)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let sourceAttributes: [FileAttributeKey: Any] = try fm.attributesOfItem(atPath: file.path)
        let modified: Date = try #require(sourceAttributes[.modificationDate] as? Date)
        let created: Date = try #require(sourceAttributes[.creationDate] as? Date)

        // The entry is named by the offer, not by the file: the receiver
        // extracts it under exactly this name.
        let out = try roundTrip(
            .file(file, name: "renamed.bin", byteCount: payload.count), in: scratch)

        #expect(try fm.contentsOfDirectory(atPath: out.path) == ["renamed.bin"])
        let entry = out.appendingPathComponent("renamed.bin")
        #expect(try Data(contentsOf: entry) == payload)
        let attributes: [FileAttributeKey: Any] = try fm.attributesOfItem(atPath: entry.path)
        let mode: Int? = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o640)
        let restoredModified: Date = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(restoredModified.timeIntervalSince(modified)) < 0.001)
        let restoredCreated: Date = try #require(attributes[.creationDate] as? Date)
        #expect(abs(restoredCreated.timeIntervalSince(created)) < 0.001)
    }

    @Test("a file source carries exactly the byte count its offer declared")
    func fileSourceCarriesTheDeclaredByteCount() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let file = scratch.appendingPathComponent("grew.bin")
        let payload = patternedBytes(count: 8192, multiplier: 1, offset: 0)
        try payload.write(to: file)

        // A file that grew between the offer's stat and the paste is sent as the
        // prefix the offer described, so the entry can never disagree with the
        // size its header declares.
        let out = try roundTrip(.file(file, name: "grew.bin", byteCount: 1024), in: scratch)
        #expect(try Data(contentsOf: out.appendingPathComponent("grew.bin")) == payload.prefix(1024))
    }

    @Test("a locked file source extracts unlocked, so staging can move and remove it")
    func lockedFileSourceExtractsUnlocked() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let file = scratch.appendingPathComponent("locked.bin")
        try Data(repeating: 0x5C, count: 2048).write(to: file)
        try fm.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: file.path) }

        let out = try roundTrip(.file(file, name: "locked.bin", byteCount: 2048), in: scratch)
        let entry = out.appendingPathComponent("locked.bin")
        let attributes: [FileAttributeKey: Any] = try fm.attributesOfItem(atPath: entry.path)
        let immutable: Bool? = attributes[.immutable] as? Bool
        #expect(immutable != true)
        // The proof that matters: the staged file can be renamed and deleted.
        let moved = out.appendingPathComponent("moved.bin")
        try fm.moveItem(at: entry, to: moved)
        try fm.removeItem(at: moved)
    }

    @Test("a blob source round-trips as one entry")
    func blobSourceRoundTrips() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let payload = patternedBytes(count: 64 * 1024, multiplier: 13, offset: 5)
        let out = try roundTrip(.blob(payload, name: "clip.png"), in: scratch)
        #expect(try fm.contentsOfDirectory(atPath: out.path) == ["clip.png"])
        #expect(try Data(contentsOf: out.appendingPathComponent("clip.png")) == payload)
    }

    // MARK: - Archive shape

    @Test("archive entries carry neither a per-entry digest nor extended attributes")
    func entriesCarryNeitherDigestNorExtendedAttributes() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 64 * 1024).write(to: source.appendingPathComponent("a.bin"))
        let tagged = source.appendingPathComponent("b.txt")
        try "b".write(to: tagged, atomically: true, encoding: .utf8)
        let xattrValue = Data("kept out of the archive".utf8)
        #expect(
            xattrValue.withUnsafeBytes { raw in
                setxattr(tagged.path, "app.kernova.test", raw.baseAddress, raw.count, 0, 0)
            } == 0)

        let archive = scratch.appendingPathComponent("tree.aar")
        try ClipboardArchive.archiveBytes(of: .directory(source)).write(to: archive)

        let file = try #require(
            ArchiveByteStream.fileStream(
                path: FilePath(archive.path), mode: .readOnly, options: [], permissions: []))
        defer { try? file.close() }
        let decompress = try #require(ArchiveByteStream.decompressionStream(readingFrom: file))
        defer { try? decompress.close() }
        let decode = try #require(ArchiveStream.decodeStream(readingFrom: decompress))
        defer { try? decode.close() }

        var paths: Set<String> = []
        while let header = try decode.readHeader() {
            // `SH2` would make the encoder hash each file in full before its
            // first payload byte could leave; `XAT` is CLIPBOARD.md §6's
            // accepted gap, which the file above carries one of.
            #expect(header.field(forKey: ArchiveHeader.FieldKey("SH2")) == nil)
            #expect(header.field(forKey: ArchiveHeader.FieldKey("XAT")) == nil)
            if case .string(_, let path)? = header.field(forKey: ArchiveHeader.FieldKey("PAT")) {
                paths.insert(path)
            }
        }
        #expect(paths.isSuperset(of: ["a.bin", "b.txt"]))
    }

    @Test("an archive is an LZ4-compressed stream")
    func archiveBytesAreLZ4Compressed() throws {
        // The codec is stamped in the compression stream's first four bytes. The
        // decompressor auto-detects it, so only the producing side pins it —
        // which is what keeps the receiver working whatever it is handed.
        let bytes = try ClipboardArchive.archiveBytes(
            of: .blob(Data(repeating: 0x5A, count: 64 * 1024), name: "b.bin"))
        #expect(bytes.prefix(4) == Data("pbz4".utf8))
    }

    @Test("the counted total is in the payload's own bytes, not the compressed archive's")
    func countedTotalIsInThePayloadsUnit() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        // One repeated byte, so the archive is a fraction of the payload and a
        // count that slipped to compressed bytes would be unmistakable.
        let file = scratch.appendingPathComponent("big.log")
        let payload = Data(repeating: 0x41, count: 1 << 20)
        try payload.write(to: file)

        let sink = ArchiveBytesSink()
        let counted = ArchiveByteCounter()
        let failure = ClipboardArchiveCodec.encode(
            .file(file, name: "big.log", byteCount: payload.count), into: sink, counted: counted)
        #expect(failure == nil)
        #expect(sink.bytes.count < payload.count)
        #expect(counted.value >= payload.count)
        #expect(counted.value <= payload.count + ClipboardStreamTuning.fileExtractAllowance)
    }

    // MARK: - The output guard

    @Test("the extract guard is consulted once per pacing quantum")
    func extractGuardIsPacedByItsQuantum() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        // Incompressible, so the tree the guard counts is the size written.
        let quantum = ClipboardStreamTuning.extractPacingBytes
        let payload = try randomBytes(count: 4 * quantum)
        #expect(payload.count == 4 * quantum)
        try payload.write(to: source.appendingPathComponent("random.bin"))

        let advances = Box(0)
        let failure = ClipboardArchiveCodec.extract(
            from: ArchiveBytesSource(
                bytes: try ClipboardArchive.archiveBytes(of: .directory(source))),
            into: try makeDestination(in: scratch), counted: ArchiveByteCounter(),
            pacingBytes: quantum, onOutputAdvanced: { _ in advances.value += 1 })

        #expect(failure == nil)
        // Paced by anything coarser — the whole archive, or the compressed bytes
        // arriving — a payload this size would report once, and the free-space
        // and ceiling checks would run once with it.
        #expect(advances.value >= payload.count / quantum - 1)
    }

    @Test("a refusing guard stops the extract, and its reason survives the archive's rewrapping")
    func extractGuardRefusalSurvivesRewrapping() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let quantum = 64 * 1024
        let payload = try randomBytes(count: 16 * quantum)
        try payload.write(to: source.appendingPathComponent("random.bin"))

        let refusal = ArchiveRefusalBox()
        let guarded = refusal.guarding { written in
            guard written <= quantum else {
                throw ClipboardArchiveStreamError.outputRefused(.overAdvertisedSize)
            }
        }
        let destination = try makeDestination(in: scratch)
        let failure = ClipboardArchiveCodec.extract(
            from: ArchiveBytesSource(
                bytes: try ClipboardArchive.archiveBytes(of: .directory(source))),
            into: destination, counted: ArchiveByteCounter(), pacingBytes: quantum,
            onOutputAdvanced: guarded)

        #expect(failure != nil)
        // AppleArchive rewraps whatever a stream callback throws in an error of
        // its own, so the box is the only place the consumer's own reason for
        // stopping is still legible.
        #expect(
            refusal.value as? ClipboardArchiveStreamError
                == ClipboardArchiveStreamError.outputRefused(.overAdvertisedSize))
        #expect(
            landedByteCount(at: destination.appendingPathComponent("random.bin")) < payload.count)
    }

    // MARK: - Failures

    @Test("encoding a nonexistent folder fails")
    func missingSourceFails() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missing = scratch.appendingPathComponent("nope", isDirectory: true)
        // An empty archive here would be a folder silently arriving empty.
        #expect(throws: (any Error).self) {
            _ = try ClipboardArchive.archiveBytes(of: .directory(missing))
        }
    }

    @Test("a file source naming a directory or a missing path fails the encode")
    func fileSourceRequiresARegularFile() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(throws: (any Error).self) {
            _ = try ClipboardArchive.archiveBytes(of: .file(scratch, name: "dir", byteCount: 0))
        }
        #expect(throws: (any Error).self) {
            _ = try ClipboardArchive.archiveBytes(
                of: .file(
                    scratch.appendingPathComponent("nope.bin"), name: "nope.bin", byteCount: 16))
        }
    }

    @Test("a file source that ends before its declared byte count fails the encode")
    func fileSourceShorterThanDeclaredFails() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let file = scratch.appendingPathComponent("shrank.bin")
        try Data(repeating: 0x11, count: 4096).write(to: file)

        // The entry's header has already declared the larger size, so the
        // archive can only be abandoned — never quietly closed short.
        #expect(throws: (any Error).self) {
            _ = try ClipboardArchive.archiveBytes(
                of: .file(file, name: "shrank.bin", byteCount: 8192))
        }
    }

    @Test("a truncated archive fails the extract rather than half-landing")
    func truncatedArchiveFailsTheExtract() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xAB, count: 256 * 1024)
        try payload.write(to: source.appendingPathComponent("big.bin"))

        let bytes = try ClipboardArchive.archiveBytes(of: .directory(source))
        let dest = try makeDestination(in: scratch)
        #expect(throws: (any Error).self) {
            try ClipboardArchive.extract(bytes.prefix(bytes.count / 2), into: dest)
        }
        // Whatever partial output is left is the caller's to remove; what the
        // extract must never do is report success over an incomplete tree.
        #expect(landedByteCount(at: dest.appendingPathComponent("big.bin")) < payload.count)
    }

    @Test("garbage in place of an archive fails the extract")
    func garbageInputFailsTheExtract() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let dest = try makeDestination(in: scratch)

        #expect(throws: (any Error).self) {
            try ClipboardArchive.extract(Data("not a valid archive".utf8), into: dest)
        }
        #expect(try fm.contentsOfDirectory(atPath: dest.path).isEmpty)
    }
}
