import Foundation
import Testing

@testable import KernovaProtocol

@Suite("ClipboardFileStaging")
struct ClipboardFileStagingTests {
    /// A fresh staging instance rooted in a unique temp directory.
    private func makeStaging(
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil
    ) -> ClipboardFileStaging {
        ClipboardFileStaging(
            label: "test-\(UUID().uuidString)",
            tempRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true),
            freeSpaceProvider: freeSpaceProvider
        )
    }

    @Test("a sink writes streamed chunks and commit keeps the file with the right name")
    func sinkWritesAndCommits() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let sink = try staging.makeSink(generation: 1, filename: "photo.png")
        try sink.write(Data([0x89, 0x50]))
        try sink.write(Data([0x4E, 0x47]))
        let url = try sink.commit()

        #expect(url.lastPathComponent == "photo.png")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("abort deletes the partial file")
    func abortDeletesPartial() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let sink = try staging.makeSink(generation: 1, filename: "partial.bin")
        try sink.write(Data([1, 2, 3]))
        let url = sink.url
        #expect(FileManager.default.fileExists(atPath: url.path))

        sink.abort()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("the last 3 generations survive; a 4th evicts only the oldest")
    func keepsGenerationHistory() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        var dirs: [URL] = []
        for generation in 1...4 {
            let sink = try staging.makeSink(
                generation: UInt64(generation), filename: "g\(generation).bin")
            try sink.write(Data([UInt8(generation)]))
            try sink.commit()
            dirs.append(sink.url.deletingLastPathComponent())
        }

        // Generation 1's directory was evicted when generation 4 arrived; 2–4 survive.
        #expect(!FileManager.default.fileExists(atPath: dirs[0].path))
        #expect(FileManager.default.fileExists(atPath: dirs[1].path))
        #expect(FileManager.default.fileExists(atPath: dirs[2].path))
        #expect(FileManager.default.fileExists(atPath: dirs[3].path))
    }

    @Test("sinks for the same generation share one directory")
    func sameGenerationSharesDirectory() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let a = try staging.makeSink(generation: 7, filename: "a.bin")
        let b = try staging.makeSink(generation: 7, filename: "b.bin")
        try a.commit()
        try b.commit()
        #expect(a.url.deletingLastPathComponent() == b.url.deletingLastPathComponent())
    }

    @Test("same-named sinks in one generation get distinct, non-colliding URLs")
    func sameNameSinksDeduped() throws {
        // A multi-file copy can carry two payloads that share a name; the second
        // sink must not reuse the first's path (which would collapse them).
        let staging = makeStaging()
        defer { staging.sweep() }

        let a = try staging.makeSink(generation: 1, filename: "dup.txt")
        try a.write(Data("first".utf8))
        let b = try staging.makeSink(generation: 1, filename: "dup.txt")
        try b.write(Data("second".utf8))
        let urlA = try a.commit()
        let urlB = try b.commit()

        #expect(urlA != urlB)
        #expect(urlA.lastPathComponent == "dup.txt")
        #expect(urlB.lastPathComponent == "dup (2).txt")
        #expect(try Data(contentsOf: urlA) == Data("first".utf8))
        #expect(try Data(contentsOf: urlB) == Data("second".utf8))
    }

    @Test("adopt de-dups a repeated filename in one generation")
    func adoptDedupsSameName() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        // Two distinct external files that happen to share a name.
        let extDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: extDir.appendingPathComponent("one"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: extDir.appendingPathComponent("two"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extDir) }
        let srcA = extDir.appendingPathComponent("one/dup.bin")
        let srcB = extDir.appendingPathComponent("two/dup.bin")
        try Data("A".utf8).write(to: srcA)
        try Data("B".utf8).write(to: srcB)

        let destA = try staging.adopt(externalFile: srcA, generation: 1, filename: "dup.bin")
        let destB = try staging.adopt(externalFile: srcB, generation: 1, filename: "dup.bin")

        #expect(destA != destB)
        #expect(try Data(contentsOf: destA) == Data("A".utf8))
        #expect(try Data(contentsOf: destB) == Data("B".utf8))
    }

    @Test("sweep removes the staging root")
    func sweepRemovesRoot() throws {
        let staging = makeStaging()
        let sink = try staging.makeSink(generation: 1, filename: "x.bin")
        try sink.commit()
        let dir = sink.url.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir.path))

        staging.sweep()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("hasCapacity reflects the injected free-space provider")
    func freeSpaceGuard() {
        let tightStaging = makeStaging(freeSpaceProvider: { _ in 10 * 1024 * 1024 })  // 10 MiB
        defer { tightStaging.sweep() }
        // 1 MiB + the default 64 MiB margin exceeds 10 MiB → no capacity.
        #expect(!tightStaging.hasCapacity(forByteCount: 1 * 1024 * 1024))
        // With no margin, 1 MiB fits in 10 MiB.
        #expect(tightStaging.hasCapacity(forByteCount: 1 * 1024 * 1024, margin: 0))

        let roomyStaging = makeStaging(freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })  // 100 GiB
        defer { roomyStaging.sweep() }
        #expect(roomyStaging.hasCapacity(forByteCount: 1 * 1024 * 1024 * 1024))  // 1 GiB fits

        let unknownStaging = makeStaging(freeSpaceProvider: { _ in nil })
        defer { unknownStaging.sweep() }
        // Unknown capacity is treated as "fits" — never block on a failed query.
        #expect(unknownStaging.hasCapacity(forByteCount: Int.max - ClipboardStreamTuning.freeSpaceMargin))
    }

    @Test("a crafted filename can't escape the generation directory")
    func sanitizesPathTraversal() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let sink = try staging.makeSink(generation: 1, filename: "../../escape.png")
        let url = sink.url
        #expect(url.lastPathComponent == "escape.png")
        #expect(url.deletingLastPathComponent().lastPathComponent != "..")
    }

    @Test(
        "a dot-only filename falls back to a safe name",
        arguments: ["..", "."])
    func sanitizesDotOnlyNames(_ name: String) throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let sink = try staging.makeSink(generation: 1, filename: name)
        try sink.write(Data([1]))
        try sink.commit()
        #expect(sink.url.lastPathComponent == "clipboard-file")
        #expect(FileManager.default.fileExists(atPath: sink.url.path))
    }

    // MARK: - Directory / tree reservations (Phase 2)

    @Test("reserveURL claims a placeholder; same-named reserves get distinct paths")
    func reserveURLClaimsAndDedups() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let a = try staging.reserveURL(generation: 1, filename: "Folder.aar")
        // An empty placeholder claims the name so a later reserve can't collide.
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(a.lastPathComponent == "Folder.aar")

        let b = try staging.reserveURL(generation: 1, filename: "Folder.aar")
        #expect(a != b)
        #expect(b.lastPathComponent == "Folder (2).aar")
    }

    @Test("reserveDirectory creates an empty directory named exactly `name`")
    func reserveDirectoryKeepsName() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let dir = try staging.reserveDirectory(generation: 1, name: "MyFolder")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(dir.lastPathComponent == "MyFolder")
    }

    @Test("reserveDirectory keeps the exact name despite a sibling archive of the same base")
    func reserveDirectoryNameSurvivesSiblingArchive() throws {
        // The receive path stages the streamed `.aar` (named after the folder)
        // beside the extracted tree. Nesting the directory under a fresh UUID
        // parent keeps its name exact instead of degrading to "MyFolder (2)".
        let staging = makeStaging()
        defer { staging.sweep() }

        _ = try staging.reserveURL(generation: 5, filename: "MyFolder")  // the staged archive
        let dir = try staging.reserveDirectory(generation: 5, name: "MyFolder")
        #expect(dir.lastPathComponent == "MyFolder")
    }

    @Test("reserveDirectory sanitizes a path-traversal name")
    func reserveDirectorySanitizes() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let dir = try staging.reserveDirectory(generation: 1, name: "../../escape")
        #expect(dir.lastPathComponent == "escape")
        #expect(dir.deletingLastPathComponent().lastPathComponent != "..")
    }

    @Test("reserved trees and archives ride the generation window (3 newest survive)")
    func reservationsRideGenerationWindow() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        var dirs: [URL] = []
        for generation in 1...4 {
            dirs.append(try staging.reserveDirectory(generation: UInt64(generation), name: "g"))
        }
        // Generation 1's directory tree is evicted when generation 4 arrives.
        #expect(!FileManager.default.fileExists(atPath: dirs[0].path))
        #expect(FileManager.default.fileExists(atPath: dirs[1].path))
        #expect(FileManager.default.fileExists(atPath: dirs[3].path))
    }
}
