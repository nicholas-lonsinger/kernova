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
        let url = sink.commit()

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
            sink.commit()
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
        a.commit()
        b.commit()
        #expect(a.url.deletingLastPathComponent() == b.url.deletingLastPathComponent())
    }

    @Test("sweep removes the staging root")
    func sweepRemovesRoot() throws {
        let staging = makeStaging()
        let sink = try staging.makeSink(generation: 1, filename: "x.bin")
        sink.commit()
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
        sink.commit()
        #expect(sink.url.lastPathComponent == "clipboard-file")
        #expect(FileManager.default.fileExists(atPath: sink.url.path))
    }
}
