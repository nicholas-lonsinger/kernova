import Foundation
import Testing

@testable import KernovaProtocol

@Suite("ClipboardFileStaging")
struct ClipboardFileStagingTests {
    @Test("stages filename-bearing reps to real files with the right name and bytes")
    func stagesFiles() throws {
        let staging = ClipboardFileStaging(label: "test-\(UUID().uuidString)")
        defer { staging.sweep() }

        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let staged = staging.stage([
            .init(uti: "public.png", data: bytes, filename: "photo.png"),
            .init(uti: "public.utf8-plain-text", data: Data("hi".utf8)),  // no filename → not staged
        ])

        #expect(staged.count == 1)
        let only = try #require(staged.first)
        #expect(only.uti == "public.png")
        #expect(only.url.lastPathComponent == "photo.png")
        #expect(FileManager.default.fileExists(atPath: only.url.path))
        #expect(try Data(contentsOf: only.url) == bytes)
    }

    @Test("stageAsync writes the same files as the synchronous stage")
    func stageAsyncMatchesStage() async throws {
        let reps: [ClipboardContent.Representation] = [
            .init(uti: "public.png", data: Data([1, 2, 3]), filename: "a.png"),
            .init(uti: "public.plain-text", data: Data("hi".utf8), filename: "b.txt"),
            .init(uti: "public.utf8-plain-text", data: Data("inline".utf8)),  // no filename → not staged
        ]
        let syncStaging = ClipboardFileStaging(label: "parity-sync-\(UUID().uuidString)")
        defer { syncStaging.sweep() }
        let asyncStaging = ClipboardFileStaging(label: "parity-async-\(UUID().uuidString)")
        defer { asyncStaging.sweep() }

        let syncStaged = syncStaging.stage(reps)
        let asyncStaged = await asyncStaging.stageAsync(reps)

        #expect(asyncStaged.map(\.uti) == syncStaged.map(\.uti))
        #expect(
            asyncStaged.map { $0.url.lastPathComponent } == syncStaged.map { $0.url.lastPathComponent })
        // The same bytes landed on disk for each staged representation.
        for staged in asyncStaged {
            let written = try Data(contentsOf: staged.url)
            #expect(written == reps.first { $0.uti == staged.uti }?.data)
        }
    }

    @Test("a fresh generation supersedes (deletes) the previous one")
    func supersedesPreviousGeneration() {
        let staging = ClipboardFileStaging(label: "test-\(UUID().uuidString)")
        defer { staging.sweep() }

        let first = staging.stage([.init(uti: "public.png", data: Data([1]), filename: "a.png")])
        let firstDir = first.first?.url.deletingLastPathComponent()
        #expect(firstDir.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        let second = staging.stage([.init(uti: "public.png", data: Data([2]), filename: "b.png")])
        // The previous generation directory is gone; the new one exists.
        #expect(firstDir.map { FileManager.default.fileExists(atPath: $0.path) } == false)
        #expect(second.first.map { FileManager.default.fileExists(atPath: $0.url.path) } == true)
    }

    @Test("content with no filename'd reps stages nothing")
    func nothingToStage() {
        let staging = ClipboardFileStaging(label: "test-\(UUID().uuidString)")
        defer { staging.sweep() }
        let staged = staging.stage([.init(uti: "public.png", data: Data([1]))])
        #expect(staged.isEmpty)
    }

    @Test("sweep removes the staging root")
    func sweepRemovesRoot() {
        let staging = ClipboardFileStaging(label: "test-\(UUID().uuidString)")
        let staged = staging.stage([.init(uti: "public.png", data: Data([1]), filename: "x.png")])
        let dir = staged.first?.url.deletingLastPathComponent()
        #expect(dir.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        staging.sweep()
        #expect(dir.map { FileManager.default.fileExists(atPath: $0.path) } == false)
    }

    @Test("a crafted filename can't escape the generation directory")
    func sanitizesPathTraversal() throws {
        let staging = ClipboardFileStaging(label: "test-\(UUID().uuidString)")
        defer { staging.sweep() }

        let staged = staging.stage([
            .init(uti: "public.png", data: Data([1]), filename: "../../escape.png")
        ])
        let url = try #require(staged.first?.url)
        // Reduced to a single component inside the generation dir.
        #expect(url.lastPathComponent == "escape.png")
        #expect(url.deletingLastPathComponent().lastPathComponent != "..")
    }

    @Test(
        "a dot-only filename falls back to a safe name",
        arguments: ["..", "."])
    func sanitizesDotOnlyNames(_ name: String) throws {
        // (An empty filename is filtered out before sanitize — it means "not a
        // file payload" — so the reachable fallback cases are the dot-only
        // names, which `lastPathComponent` leaves intact.)
        let staging = ClipboardFileStaging(label: "test-\(UUID().uuidString)")
        defer { staging.sweep() }

        let staged = staging.stage([.init(uti: "public.data", data: Data([1]), filename: name)])
        let url = try #require(staged.first?.url)
        // The dot-only component must not reach appendingPathComponent; it's
        // replaced with the literal fallback inside the generation dir.
        #expect(url.lastPathComponent == "clipboard-file")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
