import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Unit tests for the one free-name search and its Finder-style spelling.
@Suite("NameUniquing", .caseScoped)
struct NameUniquingTests {
    private let scratch = TestScratchDirectory(prefix: "NameUniquingTests")

    /// This test's empty directory, plus the files named in `seeded`.
    private func makeDirectory(seeded: [String] = []) throws -> URL {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        for name in seeded {
            FileManager.default.createFile(
                atPath: scratch.url.appendingPathComponent(name).path, contents: Data())
        }
        return scratch.url
    }

    private func name(in dir: URL, _ filename: String) -> String {
        NameUniquing.uniqueDestination(in: dir, filename: filename).lastPathComponent
    }

    // MARK: - Uniquing a destination

    @Test("several collisions count past every taken name")
    func countsPastSeveralCollisions() throws {
        let dir = try makeDirectory(seeded: ["report.pdf", "report 2.pdf"])

        #expect(name(in: dir, "report.pdf") == "report 3.pdf")
    }

    @Test("a multi-dot name counts up before the last extension only")
    func treatsOnlyTheLastComponentAsAnExtension() throws {
        let dir = try makeDirectory(seeded: ["archive.tar.gz"])

        #expect(name(in: dir, "archive.tar.gz") == "archive.tar 2.gz")
    }

    @Test(
        "an edge-case name is kept byte-for-byte when free and counts up where Finder would",
        arguments: [
            (".hidden", ".hidden 2"), ("a.", "a. 2"), ("a..b", "a. 2.b"),
            ("clipboard-file", "clipboard-file 2"),
        ])
    func keepsEdgeCaseNames(_ filename: String, _ second: String) throws {
        let dir = try makeDirectory()
        #expect(name(in: dir, filename) == filename)

        FileManager.default.createFile(
            atPath: dir.appendingPathComponent(filename).path, contents: Data())
        #expect(name(in: dir, filename) == second)
    }

    @Test("a dangling symlink at the name is taken, so the move onto the result succeeds")
    func countsPastADanglingSymlink() throws {
        let dir = try makeDirectory()
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("report.pdf"),
            withDestinationURL: dir.appendingPathComponent("missing"))
        let source = dir.appendingPathComponent("source")
        FileManager.default.createFile(atPath: source.path, contents: Data())

        let destination = NameUniquing.uniqueDestination(in: dir, filename: "report.pdf")
        #expect(destination.lastPathComponent == "report 2.pdf")
        try FileManager.default.moveItem(at: source, to: destination)
    }

    @Test("a peer-supplied name cannot escape the destination directory")
    func sanitizesTraversal() throws {
        let dir = try makeDirectory()

        let escaped = NameUniquing.uniqueDestination(in: dir, filename: "../escape.txt")
        #expect(escaped.lastPathComponent == "escape.txt")
        #expect(escaped.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)

        let nested = NameUniquing.uniqueDestination(in: dir, filename: "a/b.txt")
        #expect(nested.lastPathComponent == "b.txt")
        #expect(nested.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)

        for degenerate in ["", ".", ".."] {
            #expect(name(in: dir, degenerate) == "clipboard-file")
        }
    }

    // MARK: - Counting after the whole name

    @Test("the bare search counts after the whole name, dots included")
    func countsAfterTheWholeName() {
        #expect(NameUniquing.firstAvailable("macOS 15.1") { $0 == "macOS 15.1" } == "macOS 15.1 2")
        #expect(NameUniquing.firstAvailable("free") { _ in false } == "free")
    }

    // MARK: - Sanitization

    @Test("an empty or dot-only name falls back rather than naming the directory")
    func sanitizesDegenerateNames() {
        #expect(NameUniquing.sanitizedComponent("") == "clipboard-file")
        #expect(NameUniquing.sanitizedComponent(".") == "clipboard-file")
        #expect(NameUniquing.sanitizedComponent("..") == "clipboard-file")
        // A bare separator survives as a placeholder character rather than the
        // fallback — still one harmless component, which is the whole contract.
        #expect(NameUniquing.sanitizedComponent("/") == "_")
    }

    @Test("an ordinary name passes through sanitization untouched")
    func keepsOrdinaryNames() {
        #expect(NameUniquing.sanitizedComponent("Some File.txt") == "Some File.txt")
        #expect(NameUniquing.sanitizedComponent(".hidden") == ".hidden")
    }
}
