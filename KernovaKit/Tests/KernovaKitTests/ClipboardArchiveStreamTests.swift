import AppleArchive
import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaKit

/// The archive pipeline with no archive file anywhere: a source — a folder, one
/// file, or resident bytes — is encoded on demand by `ClipboardArchiveReader`
/// and extracted as it arrives by `ClipboardArchiveExtractSink`.
@Suite("ClipboardArchiveStream")
struct ClipboardArchiveStreamTests {
    /// A unique scratch directory removed when the test ends.
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirstream-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDestination(in scratch: URL, named name: String = "out") throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every byte the encoder produces for `directory`.
    private func archiveBytes(of directory: URL, chunkSize: Int = 64 << 10) throws -> Data {
        let reader = ClipboardArchiveReader(source: .directory(directory), label: "test")
        var bytes = Data()
        while true {
            let chunk = try reader.read(upTo: chunkSize)
            if chunk.isEmpty { break }
            bytes.append(chunk)
        }
        return bytes
    }

    /// Feeds `bytes` through a fresh extract sink in `chunkSize` slices.
    @discardableResult
    private func extract(_ bytes: Data, into destination: URL, chunkSize: Int = 64 << 10) throws
        -> URL
    {
        let sink = ClipboardArchiveExtractSink(destinationURL: destination, label: "test")
        do {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + chunkSize, bytes.count)
                try sink.write(bytes[offset..<end])
                offset = end
            }
            return try sink.commit()
        } catch {
            sink.abort()
            throw error
        }
    }

    /// Pipes the encoder straight into the extract sink — both ends live at once,
    /// as they are in a real transfer — and returns the streamed byte count.
    @discardableResult
    private func stream(
        from source: URL, into destination: URL, chunkSize: Int = 64 << 10,
        capacityBytes: Int = 1 << 20
    ) throws -> Int {
        let reader = ClipboardArchiveReader(
            source: .directory(source), label: "test", capacityBytes: capacityBytes)
        let sink = ClipboardArchiveExtractSink(
            destinationURL: destination, label: "test", capacityBytes: capacityBytes)
        var streamed = 0
        do {
            while true {
                let chunk = try reader.read(upTo: chunkSize)
                if chunk.isEmpty { break }
                streamed += chunk.count
                try sink.write(chunk)
            }
            _ = try sink.commit()
        } catch {
            reader.cancel()
            sink.abort()
            throw error
        }
        return streamed
    }

    // MARK: - Fidelity

    @Test("streaming preserves a nested tree, contents, an empty dir, and the exec bit")
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

        let dest = try makeDestination(in: scratch)
        let streamed = try stream(from: source, into: dest)
        #expect(streamed > 0)

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
        // Nothing but the tree: no archive is ever materialized on either side.
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

        let dest = try makeDestination(in: scratch)
        try stream(from: source, into: dest)

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

        let dest = try makeDestination(in: scratch)
        try stream(from: source, into: dest)

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

        let dest = try makeDestination(in: scratch)
        try stream(from: source, into: dest)

        #expect(
            try String(
                contentsOf: dest.appendingPathComponent("Ünïcødé 🎉/naïve — файл.txt"),
                encoding: .utf8) == "ok")
    }

    @Test("archive entries carry no per-entry digest — the stream-level hash is the only one")
    func entriesCarryNoDigest() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 64 * 1024).write(to: source.appendingPathComponent("a.bin"))
        try "b".write(to: source.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let archive = scratch.appendingPathComponent("tree.aar")
        try archiveBytes(of: source).write(to: archive)

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
            #expect(header.field(forKey: ArchiveHeader.FieldKey("SH2")) == nil)
            if case .string(_, let path)? = header.field(forKey: ArchiveHeader.FieldKey("PAT")) {
                paths.insert(path)
            }
        }
        #expect(paths.isSuperset(of: ["a.bin", "b.txt"]))
    }

    @Test("an empty directory streams real bytes and extracts to an empty tree")
    func emptyDirectoryStreams() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)

        let dest = try makeDestination(in: scratch)
        // Archive-header bytes, so a streamed folder is never legitimately
        // zero-length — which is what lets `End.total_bytes > 0` hold.
        #expect(try stream(from: source, into: dest) > 0)
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

        let dest = try makeDestination(in: scratch)
        try stream(from: source, into: dest)
        #expect(fm.fileExists(atPath: dest.appendingPathComponent(".keep").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("sub/.keep").path))
    }

    @Test("one byte per write still produces the exact tree")
    func byteAtATimeFramingRoundTrips() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(
            at: source.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try "hello".write(
            to: source.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)

        let dest = try makeDestination(in: scratch)
        // Wire framing carries no meaning to the codec: the archive is one byte
        // stream however it is chopped up.
        try extract(try archiveBytes(of: source), into: dest, chunkSize: 1)
        #expect(
            try String(contentsOf: dest.appendingPathComponent("sub/a.txt"), encoding: .utf8)
                == "hello")
    }

    @Test("a tiny pipe capacity forces both ends to park and still round-trips")
    func tinyCapacityRoundTrips() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        // Incompressible, so the archive is large enough to fill a 4 KiB pipe
        // many times over.
        var payload = Data(count: 512 * 1024)
        payload.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<raw.count { base[index] = UInt8.random(in: 0...255) }
        }
        try payload.write(to: source.appendingPathComponent("random.bin"))

        let dest = try makeDestination(in: scratch)
        try stream(from: source, into: dest, chunkSize: 4096, capacityBytes: 4096)
        #expect(try Data(contentsOf: dest.appendingPathComponent("random.bin")) == payload)
    }

    // MARK: - One-entry sources

    @Test("a file source round-trips byte-identically under its entry name, with mode and mtime")
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

        // The entry is named by the offer, not by the file: the receiver
        // extracts it under exactly this name.
        let out = try extractedClipboardArchive(
            try clipboardArchiveBytes(of: .file(file, name: "renamed.bin", byteCount: payload.count))
        )
        defer { try? fm.removeItem(at: out.deletingLastPathComponent()) }

        #expect(try fm.contentsOfDirectory(atPath: out.path) == ["renamed.bin"])
        let entry = out.appendingPathComponent("renamed.bin")
        #expect(try Data(contentsOf: entry) == payload)
        let attributes: [FileAttributeKey: Any] = try fm.attributesOfItem(atPath: entry.path)
        let mode: Int? = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o640)
        let restored: Date = try #require(attributes[.modificationDate] as? Date)
        let drift: TimeInterval = abs(restored.timeIntervalSince(modified))
        #expect(drift < 0.001)
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
        let out = try extractedClipboardArchive(
            try clipboardArchiveBytes(of: .file(file, name: "grew.bin", byteCount: 1024)))
        defer { try? fm.removeItem(at: out.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: out.appendingPathComponent("grew.bin")) == payload.prefix(1024))
    }

    @Test("a file source that ends before its declared byte count fails the read")
    func fileSourceShorterThanDeclaredFails() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let file = scratch.appendingPathComponent("shrank.bin")
        try Data(repeating: 0x11, count: 4096).write(to: file)

        // The entry's header has already declared the larger size, so the
        // archive can only be abandoned — never quietly closed short.
        let reader = ClipboardArchiveReader(
            source: .file(file, name: "shrank.bin", byteCount: 8192), label: "test")
        #expect(throws: (any Error).self) {
            while try !reader.read(upTo: 64 << 10).isEmpty {}
        }
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

        let out = try extractedClipboardArchive(
            try clipboardArchiveBytes(of: .file(file, name: "locked.bin", byteCount: 2048)))
        defer { try? fm.removeItem(at: out.deletingLastPathComponent()) }
        let entry = out.appendingPathComponent("locked.bin")
        let attributes: [FileAttributeKey: Any] = try fm.attributesOfItem(atPath: entry.path)
        let immutable: Bool? = attributes[.immutable] as? Bool
        #expect(immutable != true)
        // The proof that matters: the staged file can be renamed and deleted.
        let moved = out.appendingPathComponent("moved.bin")
        try fm.moveItem(at: entry, to: moved)
        try fm.removeItem(at: moved)
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

        let dest = try makeDestination(in: scratch)
        try stream(from: source, into: dest)

        let entry = dest.appendingPathComponent("sub/locked.bin")
        let immutable =
            try fm.attributesOfItem(atPath: entry.path)[.immutable] as? Bool
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

        let dest = try makeDestination(in: scratch)
        try stream(from: source, into: dest)

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

    @Test("a blob source round-trips as one entry")
    func blobSourceRoundTrips() throws {
        let fm = FileManager.default
        let payload = patternedBytes(count: 64 * 1024, multiplier: 13, offset: 5)
        let out = try extractedClipboardArchive(
            try clipboardArchiveBytes(of: .blob(payload, name: "clip.png")))
        defer { try? fm.removeItem(at: out.deletingLastPathComponent()) }
        #expect(try fm.contentsOfDirectory(atPath: out.path) == ["clip.png"])
        #expect(try Data(contentsOf: out.appendingPathComponent("clip.png")) == payload)
    }

    @Test("a file source naming a directory or a missing path fails rather than ending the stream")
    func fileSourceRequiresARegularFile() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let directory = ClipboardArchiveReader(
            source: .file(scratch, name: "dir", byteCount: 0), label: "test")
        #expect(throws: (any Error).self) {
            while try !directory.read(upTo: 64 << 10).isEmpty {}
        }
        let missing = ClipboardArchiveReader(
            source: .file(
                scratch.appendingPathComponent("nope.bin"), name: "nope.bin", byteCount: 16),
            label: "test")
        #expect(throws: (any Error).self) {
            while try !missing.read(upTo: 64 << 10).isEmpty {}
        }
    }

    @Test("uncompressedByteCount counts the payload's own bytes, not the compressed wire")
    func uncompressedCountIsInThePayloadsUnit() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        // One repeated byte, so the wire is a fraction of the payload and a
        // count that slipped to wire bytes would be unmistakable.
        let file = scratch.appendingPathComponent("big.log")
        let payload = Data(repeating: 0x41, count: 1 << 20)
        try payload.write(to: file)

        let reader = ClipboardArchiveReader(
            source: .file(file, name: "big.log", byteCount: payload.count), label: "test")
        var wire = 0
        while true {
            let chunk = try reader.read(upTo: 64 << 10)
            if chunk.isEmpty { break }
            wire += chunk.count
        }
        #expect(wire < payload.count)
        #expect(reader.uncompressedByteCount >= payload.count)
        #expect(
            reader.uncompressedByteCount
                <= payload.count + ClipboardStreamTuning.fileExtractAllowance)
    }

    @Test("the wire carries an LZ4-compressed archive")
    func wireBytesAreLZ4Compressed() throws {
        // The codec is stamped in the compression stream's first four bytes. The
        // decompressor auto-detects it, so only the producing side pins it —
        // which is what keeps the receiver working whatever it is handed.
        let bytes = try clipboardArchiveBytes(
            of: .blob(Data(repeating: 0x5A, count: 64 * 1024), name: "b.bin"))
        #expect(bytes.prefix(4) == Data("pbz4".utf8))
    }

    // MARK: - Failure and cleanup

    @Test("encoding a nonexistent folder fails rather than ending the stream")
    func missingSourceFails() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missing = scratch.appendingPathComponent("nope", isDirectory: true)
        let reader = ClipboardArchiveReader(source: .directory(missing), label: "test")
        #expect(throws: (any Error).self) {
            // Drains until the encode pipeline reports its failure; an end of
            // stream here would mean a valid empty archive.
            while try !reader.read(upTo: 64 << 10).isEmpty {}
        }
    }

    @Test("a truncated archive fails the commit and leaves no tree behind")
    func truncatedArchiveLeavesNoTree() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 256 * 1024)
            .write(to: source.appendingPathComponent("big.bin"))

        let bytes = try archiveBytes(of: source)
        let dest = try makeDestination(in: scratch)
        #expect(throws: (any Error).self) {
            try extract(bytes.prefix(bytes.count / 2), into: dest)
        }
        // A streamed extract has always written part of the tree by the time
        // anything can be verified, so the cleanup is not optional.
        #expect(!fm.fileExists(atPath: dest.path))
    }

    @Test("garbage in place of an archive fails the commit and leaves no tree behind")
    func garbageInputLeavesNoTree() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let dest = try makeDestination(in: scratch)
        #expect(throws: (any Error).self) {
            try extract(Data("not a valid archive".utf8), into: dest)
        }
        #expect(!fm.fileExists(atPath: dest.path))
    }

    @Test("aborting mid-stream tears the pipeline down and removes the partial tree")
    func abortMidStreamRemovesPartialTree() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<8 {
            try Data(repeating: UInt8(index), count: 64 * 1024)
                .write(to: source.appendingPathComponent("f\(index).bin"))
        }

        let bytes = try archiveBytes(of: source)
        let dest = try makeDestination(in: scratch)
        let sink = ClipboardArchiveExtractSink(destinationURL: dest, label: "test")
        try sink.write(bytes.prefix(bytes.count / 2))
        // Blocks until the extract pipeline has unwound, so the assertion below
        // needs no wait of its own.
        sink.abort()
        #expect(!fm.fileExists(atPath: dest.path))
        // Idempotent, and a write afterwards is refused rather than parking.
        sink.abort()
        #expect(throws: (any Error).self) { try sink.write(Data([0])) }
    }

    @Test("a write landing after the archive is unpacked is dropped, and commit stays idempotent")
    func writeAfterASuccessfulExtractIsDropped() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(
            at: source.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try "hello".write(
            to: source.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)

        let dest = try makeDestination(in: scratch)
        let sink = ClipboardArchiveExtractSink(destinationURL: dest, label: "test")
        try sink.write(try archiveBytes(of: source))
        let url = try sink.commit()

        // Whatever the wire still carries once the tree is out is surplus to the
        // decoder — accepting and dropping it is what keeps a straggling chunk
        // from turning a good folder into an `extract.error`.
        try sink.write(Data([0x00]))
        #expect(try sink.commit() == url)
        #expect(
            try String(contentsOf: url.appendingPathComponent("sub/a.txt"), encoding: .utf8)
                == "hello")
    }

    @Test("writes past the drop bound are refused rather than dropped forever")
    func writesPastTheDropBoundAreRefused() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "hello".write(
            to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let capacity = 64 << 10
        let dest = try makeDestination(in: scratch)
        let sink = ClipboardArchiveExtractSink(
            destinationURL: dest, label: "test", capacityBytes: capacity)
        try sink.write(try archiveBytes(of: source))
        _ = try sink.commit()

        // A peer that never sends End keeps a transfer alive for as long as its
        // writes are taken, so the accept-and-drop window has to end somewhere.
        let block = Data(repeating: 0, count: 4096)
        var accepted = 0
        #expect(throws: (any Error).self) {
            while accepted <= capacity * 2 {
                try sink.write(block)
                accepted += block.count
            }
        }
        #expect(accepted > 0)
        #expect(accepted <= capacity)
    }

    @Test("a write after the pipeline failed is still refused")
    func writeAfterAFailedExtractStillThrows() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let dest = try makeDestination(in: scratch)

        let sink = ClipboardArchiveExtractSink(destinationURL: dest, label: "test")
        try sink.write(Data("not a valid archive".utf8))
        #expect(throws: (any Error).self) { _ = try sink.commit() }
        // A failed pipeline has nothing to feed, so the refusal has to stand.
        #expect(throws: (any Error).self) { try sink.write(Data([0])) }
        // And a repeat commit reports the same failure rather than handing back
        // the folder the first one deleted.
        #expect(throws: (any Error).self) { _ = try sink.commit() }
        #expect(!fm.fileExists(atPath: dest.path))
    }

    @Test("committing after an abort throws rather than naming a folder that was deleted")
    func commitAfterAbortThrows() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 256 * 1024)
            .write(to: source.appendingPathComponent("big.bin"))
        let bytes = try archiveBytes(of: source)

        let dest = try makeDestination(in: scratch)
        let sink = ClipboardArchiveExtractSink(destinationURL: dest, label: "test")
        try sink.write(bytes.prefix(bytes.count / 2))
        sink.abort()
        #expect(!fm.fileExists(atPath: dest.path))
        // The two endings are mutually exclusive: the tree a commit would hand
        // back is gone, so reporting success would hand out a dead URL.
        #expect(throws: ClipboardArchiveStreamError.cancelled) { _ = try sink.commit() }
    }

    @Test("cancelling the extract sink refuses further writes and fails the commit")
    func cancelRefusesFurtherWrites() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let dest = try makeDestination(in: scratch)

        let sink = ClipboardArchiveExtractSink(destinationURL: dest, label: "test")
        sink.cancel()
        #expect(throws: (any Error).self) { try sink.write(Data(repeating: 0, count: 4096)) }
        #expect(throws: (any Error).self) { _ = try sink.commit() }
        #expect(!fm.fileExists(atPath: dest.path))
    }

    @Test("failing the byte pipe releases a writer it cannot take from")
    func failingThePipeReleasesTheWriter() async throws {
        // Filled past capacity with nothing draining it, so the write below can
        // only end when the pipe does.
        let pipe = ClipboardArchiveBytePipe(capacity: 16)
        try pipe.write(Data(repeating: 0, count: 64))
        let released = AsyncGate()
        let threw = Box(false)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try pipe.write(Data([1]))
            } catch {
                threw.value = true
            }
            released.notify()
        }
        pipe.fail(ClipboardArchiveStreamError.cancelled)
        try await released.wait { threw.value }
    }

    @Test("completing the byte pipe releases a writer it will never read from")
    func completingThePipeReleasesTheWriter() async throws {
        // Filled past capacity with nothing draining it, so the write below can
        // only end when the pipe does.
        let pipe = ClipboardArchiveBytePipe(capacity: 16)
        try pipe.write(Data(repeating: 0, count: 64))
        let released = AsyncGate()
        let threw = Box(false)
        let returned = Box(false)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try pipe.write(Data([1]))
            } catch {
                threw.value = true
            }
            returned.value = true
            released.notify()
        }
        pipe.complete()
        try await released.wait { returned.value }
        // Woken, like a failure — but the reader succeeded, so nothing is wrong
        // and the writer must not be told otherwise.
        #expect(!threw.value)
        // Later bytes are taken and dropped; the reader is finished with them.
        try pipe.write(Data([2]))
        #expect(try pipe.read(upTo: 8).isEmpty)
    }

    @Test("the byte pipe drains what it holds before reporting end of stream")
    func pipeDrainsBeforeEndOfStream() throws {
        let pipe = ClipboardArchiveBytePipe(capacity: 1024)
        try pipe.write(Data([1, 2, 3]))
        try pipe.write(Data([4, 5]))
        pipe.finish()
        #expect(try pipe.read(upTo: 4) == Data([1, 2, 3, 4]))
        #expect(try pipe.read(upTo: 4) == Data([5]))
        #expect(try pipe.read(upTo: 4).isEmpty)
        // A failure after the fact still surfaces to the reader rather than
        // looking like a clean end of stream.
        pipe.fail(ClipboardArchiveStreamError.cancelled)
        #expect(throws: (any Error).self) { _ = try pipe.read(upTo: 4) }
    }

    @Test("cancelling the reader ends the encode instead of leaving it parked")
    func cancelEndsTheEncode() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4 * 1024 * 1024)
            .write(to: source.appendingPathComponent("big.bin"))

        let reader = ClipboardArchiveReader(
            source: .directory(source), label: "test", capacityBytes: 4096)
        #expect(try !reader.read(upTo: 512).isEmpty)
        reader.cancel()
        // Never an empty result, which would mean a complete archive.
        #expect(throws: (any Error).self) {
            while try !reader.read(upTo: 512).isEmpty {}
        }
    }
}
