import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The folder-transfer pipeline with no archive file anywhere: a source tree is
/// encoded on demand by `ClipboardDirectoryArchiveReader` and extracted as it
/// arrives by `ClipboardDirectoryExtractSink`.
@Suite("ClipboardDirectoryStream")
struct ClipboardDirectoryStreamTests {
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
        let reader = ClipboardDirectoryArchiveReader(directoryURL: directory, label: "test")
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
        let sink = ClipboardDirectoryExtractSink(destinationURL: destination, label: "test")
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
        let reader = ClipboardDirectoryArchiveReader(
            directoryURL: source, label: "test", capacityBytes: capacityBytes)
        let sink = ClipboardDirectoryExtractSink(
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
        #expect(ClipboardDirectoryArchive.estimatedByteCount(at: source) == 0)

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

    // MARK: - Failure and cleanup

    @Test("encoding a nonexistent folder fails rather than ending the stream")
    func missingSourceFails() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missing = scratch.appendingPathComponent("nope", isDirectory: true)
        let reader = ClipboardDirectoryArchiveReader(directoryURL: missing, label: "test")
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
        let sink = ClipboardDirectoryExtractSink(destinationURL: dest, label: "test")
        try sink.write(bytes.prefix(bytes.count / 2))
        // Blocks until the extract pipeline has unwound, so the assertion below
        // needs no wait of its own.
        sink.abort()
        #expect(!fm.fileExists(atPath: dest.path))
        // Idempotent, and a write afterwards is refused rather than parking.
        sink.abort()
        #expect(throws: (any Error).self) { try sink.write(Data([0])) }
    }

    @Test("cancelling the extract sink refuses further writes and fails the commit")
    func cancelRefusesFurtherWrites() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let dest = try makeDestination(in: scratch)

        let sink = ClipboardDirectoryExtractSink(destinationURL: dest, label: "test")
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

        let reader = ClipboardDirectoryArchiveReader(
            directoryURL: source, label: "test", capacityBytes: 4096)
        #expect(try !reader.read(upTo: 512).isEmpty)
        reader.cancel()
        // Never an empty result, which would mean a complete archive.
        #expect(throws: (any Error).self) {
            while try !reader.read(upTo: 512).isEmpty {}
        }
    }
}
