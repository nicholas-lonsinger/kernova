import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Unit tests for the naming a dropped file gets in the guest's Downloads
/// folder — Finder's own "Keep Both" convention, not staging's invisible ` (n)`
/// style.
@Suite("FinderStyleUniquing", .caseScoped)
struct FinderStyleUniquingTests {
    private let scratch = TestScratchDirectory(prefix: "FinderStyleUniquingTests")

    /// This test's empty directory, plus the files named in `seeded`.
    private func makeDirectory(seeded: [String] = []) throws -> URL {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        for name in seeded {
            FileManager.default.createFile(
                atPath: scratch.url.appendingPathComponent(name).path, contents: Data())
        }
        return scratch.url
    }

    // MARK: - Uniquing

    @Test("a free name is used as-is")
    func keepsAFreeName() throws {
        let dir = try makeDirectory()

        #expect(
            FinderStyleUniquing.uniqueDestination(in: dir, filename: "report.pdf").lastPathComponent
                == "report.pdf")
    }

    @Test("a taken name counts up before the extension, Finder-style")
    func countsUpBeforeTheExtension() throws {
        let dir = try makeDirectory(seeded: ["report.pdf"])

        let second = FinderStyleUniquing.uniqueDestination(in: dir, filename: "report.pdf")
        #expect(second.lastPathComponent == "report 2.pdf")

        FileManager.default.createFile(atPath: second.path, contents: Data())
        #expect(
            FinderStyleUniquing.uniqueDestination(in: dir, filename: "report.pdf")
                .lastPathComponent == "report 3.pdf")
    }

    @Test("an extensionless name — a folder's, say — takes a bare counter")
    func countsUpWithoutAnExtension() throws {
        let dir = try makeDirectory(seeded: ["Photos"])

        #expect(
            FinderStyleUniquing.uniqueDestination(in: dir, filename: "Photos").lastPathComponent
                == "Photos 2")
    }

    @Test("a multi-dot name counts up before the last extension only")
    func treatsOnlyTheLastComponentAsAnExtension() throws {
        let dir = try makeDirectory(seeded: ["archive.tar.gz"])

        #expect(
            FinderStyleUniquing.uniqueDestination(in: dir, filename: "archive.tar.gz")
                .lastPathComponent == "archive.tar 2.gz")
    }

    // MARK: - Sanitization

    @Test("a peer-supplied name cannot escape the destination directory")
    func sanitizesTraversal() throws {
        let dir = try makeDirectory()

        let escaped = FinderStyleUniquing.uniqueDestination(in: dir, filename: "../escape.txt")
        #expect(escaped.lastPathComponent == "escape.txt")
        #expect(escaped.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)

        let nested = FinderStyleUniquing.uniqueDestination(in: dir, filename: "a/b.txt")
        #expect(nested.lastPathComponent == "b.txt")
        #expect(nested.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    }

    @Test("an empty or dot-only name falls back rather than naming the directory")
    func sanitizesDegenerateNames() {
        #expect(FinderStyleUniquing.sanitizedComponent("") == "clipboard-file")
        #expect(FinderStyleUniquing.sanitizedComponent(".") == "clipboard-file")
        #expect(FinderStyleUniquing.sanitizedComponent("..") == "clipboard-file")
        // A bare separator survives as a placeholder character rather than the
        // fallback — still one harmless component, which is the whole contract.
        #expect(FinderStyleUniquing.sanitizedComponent("/") == "_")
    }

    @Test("an ordinary name passes through sanitization untouched")
    func keepsOrdinaryNames() {
        #expect(FinderStyleUniquing.sanitizedComponent("Some File.txt") == "Some File.txt")
        #expect(FinderStyleUniquing.sanitizedComponent(".hidden") == ".hidden")
    }
}
