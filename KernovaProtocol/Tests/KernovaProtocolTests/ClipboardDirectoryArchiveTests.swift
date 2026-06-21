import Foundation
import Testing

@testable import KernovaProtocol

@Suite("ClipboardDirectoryArchive")
struct ClipboardDirectoryArchiveTests {
    /// A unique scratch directory removed when the test ends.
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("archive → extract preserves a nested tree, contents, empty dir, and exec bit")
    func roundTripFidelity() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("a/b/c", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try "top".write(to: source.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try "deep".write(to: nested.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)
        try fm.createDirectory(
            at: source.appendingPathComponent("emptydir", isDirectory: true),
            withIntermediateDirectories: true)
        let exe = source.appendingPathComponent("run.sh")
        try "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let archive = scratch.appendingPathComponent("tree.aar")
        try ClipboardDirectoryArchive.archive(directoryAt: source, to: archive)
        #expect(fm.fileExists(atPath: archive.path))

        let dest = scratch.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try ClipboardDirectoryArchive.extract(archiveAt: archive, to: dest)

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

        let archive = scratch.appendingPathComponent("tree.aar")
        try ClipboardDirectoryArchive.archive(directoryAt: source, to: archive)
        let dest = scratch.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try ClipboardDirectoryArchive.extract(archiveAt: archive, to: dest)

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

        let archive = scratch.appendingPathComponent("tree.aar")
        try ClipboardDirectoryArchive.archive(directoryAt: source, to: archive)
        let dest = scratch.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try ClipboardDirectoryArchive.extract(archiveAt: archive, to: dest)

        #expect(
            try String(
                contentsOf: dest.appendingPathComponent("note.rtfd/TXT.rtf"), encoding: .utf8)
                == "{\\rtf1}")
    }

    @Test("an empty directory archives to a non-empty file and extracts cleanly")
    func emptyDirectoryArchives() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)

        let archive = scratch.appendingPathComponent("empty.aar")
        try ClipboardDirectoryArchive.archive(directoryAt: source, to: archive)
        // An empty folder still produces archive-header bytes (so the offer's
        // byteCount > 0 and the size guard must key on isDirectory, not size).
        let size = try #require(fm.attributesOfItem(atPath: archive.path)[.size] as? Int)
        #expect(size > 0)

        let dest = scratch.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try ClipboardDirectoryArchive.extract(archiveAt: archive, to: dest)
        #expect(try fm.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    // MARK: - Staging-aware helpers (shared by host + guest)

    private func makeStaging(
        in scratch: URL, freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil
    ) -> ClipboardFileStaging {
        ClipboardFileStaging(
            label: "archive-test-\(UUID().uuidString)",
            tempRoot: scratch.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true),
            freeSpaceProvider: freeSpaceProvider)
    }

    @Test("archivedRepresentation builds a directory rep whose archive round-trips")
    func archivedRepresentationRoundTrips() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let src = scratch.appendingPathComponent("Photos", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "p".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let staging = makeStaging(in: scratch)
        defer { staging.sweep() }

        let rep = try #require(
            try ClipboardDirectoryArchive.archivedRepresentation(
                ofDirectoryAt: src, named: "Photos", into: staging, generation: 1))
        #expect(rep.isDirectory)
        #expect(rep.uti == ClipboardDirectoryArchive.directoryUTI)
        #expect(rep.filename == "Photos")
        #expect(rep.byteCount > 0)

        // extractedDirectoryURL turns the rep back into the real tree.
        let dir = try #require(
            ClipboardDirectoryArchive.extractedDirectoryURL(for: rep, into: staging, generation: 2))
        #expect(dir.lastPathComponent == "Photos")
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "p")
    }

    @Test("extractedDirectoryURL returns nil for a non-directory rep")
    func extractedDirectoryURLRejectsNonDirectory() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staging = makeStaging(in: scratch)
        defer { staging.sweep() }
        let fileRep = ClipboardContent.Representation(
            uti: "public.data", fileURL: URL(fileURLWithPath: "/tmp/x"), byteCount: 1,
            filename: "x", isDirectory: false)
        #expect(
            ClipboardDirectoryArchive.extractedDirectoryURL(
                for: fileRep, into: staging, generation: 1) == nil)
    }

    @Test("extractedDirectoryURL returns nil when the volume lacks capacity")
    func extractedDirectoryURLRespectsCapacity() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let src = scratch.appendingPathComponent("Big", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "x".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let archive = scratch.appendingPathComponent("big.aar")
        try ClipboardDirectoryArchive.archive(directoryAt: src, to: archive)
        let size = try #require(fm.attributesOfItem(atPath: archive.path)[.size] as? Int)
        let rep = ClipboardContent.Representation(
            uti: ClipboardDirectoryArchive.directoryUTI, fileURL: archive, byteCount: size,
            filename: "Big", isDirectory: true)

        // 1 byte free → the floor check fails before any extraction is attempted.
        let tightStaging = makeStaging(in: scratch, freeSpaceProvider: { _ in 1 })
        defer { tightStaging.sweep() }
        #expect(
            ClipboardDirectoryArchive.extractedDirectoryURL(
                for: rep, into: tightStaging, generation: 1) == nil)
    }

    @Test("extracting a non-archive file throws and removes the destination")
    func extractGarbageThrowsAndCleansUp() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let notAnArchive = scratch.appendingPathComponent("garbage.aar")
        try Data("not a valid archive".utf8).write(to: notAnArchive)
        let dest = scratch.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try ClipboardDirectoryArchive.extract(archiveAt: notAnArchive, to: dest)
        }
        // The destination is removed so a partial/failed extraction never reaches
        // the pasteboard.
        #expect(!fm.fileExists(atPath: dest.path))
    }
}
