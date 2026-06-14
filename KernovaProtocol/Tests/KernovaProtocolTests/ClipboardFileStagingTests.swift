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
}
