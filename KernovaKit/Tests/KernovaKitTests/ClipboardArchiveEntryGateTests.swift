import AppleArchive
import Darwin
import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaKit

/// The receiving side's extract on entries no sender of ours writes: which it
/// refuses, naming them, which it leaves out, and which of an entry's flags
/// it withholds. Round-trip fidelity through the sender's own archives is
/// `ClipboardArchiveStreamTests`.
@Suite("ClipboardArchiveEntryGate", .caseScoped)
struct ClipboardArchiveEntryGateTests {
    private let scratch = TestScratchDirectory(prefix: "archive-gate")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    /// An empty directory to extract into, alone in a directory of its own so
    /// anything written beside it shows.
    private func makeDestination() throws -> URL {
        let destination = scratch.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    /// The byte length of `url`'s path with its symlinks resolved, as the
    /// extract writes under it.
    private func resolvedByteCount(_ url: URL) throws -> Int {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return strlen(resolved)
    }

    /// The root, then directories of 100-byte names, then a file, so the
    /// file's absolute path under a destination of `destinationByteCount`
    /// bytes is exactly `absoluteByteCount` bytes.
    private func entries(reaching absoluteByteCount: Int, under destinationByteCount: Int) -> (
        [RawArchiveEntry], file: String
    ) {
        let pathByteCount = absoluteByteCount - destinationByteCount - 1
        var entries = [RawArchiveEntry.root()]
        var path = ""
        while pathByteCount - path.utf8.count > 200 {
            path += (path.isEmpty ? "" : "/") + String(repeating: "d", count: 100)
            entries.append(.directory(path))
        }
        let prefix = path.isEmpty ? "" : path + "/"
        let file = prefix + String(repeating: "f", count: pathByteCount - prefix.utf8.count)
        entries.append(.file(file, "x"))
        return (entries, file)
    }

    // MARK: - Refused

    /// The destination is under the scratch directory, whose path runs
    /// through `/var`'s symlink, so the limit is measured on the resolved
    /// path.
    @Test("an entry whose absolute path fits PATH_MAX lands, and one byte more is refused, naming it")
    func pathLimitIsExact() throws {
        let destination = try makeDestination()
        let destinationByteCount = try resolvedByteCount(destination)

        let (fits, fitting) = entries(reaching: Int(PATH_MAX) - 1, under: destinationByteCount)
        #expect(extractFailure(try rawArchive(fits), into: destination) == nil)
        #expect(
            try Data(contentsOf: destination.appendingPathComponent(fitting)) == Data("x".utf8))

        try FileManager.default.removeItem(at: destination)
        let fresh = try makeDestination()
        let (over, overlong) = entries(reaching: Int(PATH_MAX), under: destinationByteCount)
        #expect(
            extractFailure(try rawArchive(over), into: fresh) as? ClipboardItemFailure
                == ClipboardItemFailure(itemPath: overlong, reason: .posix(ENAMETOOLONG)))
    }

    /// AppleArchive skips such an entry without a trace, reporting no
    /// failure at all.
    @Test("an entry whose path is 1,024 bytes or more is refused, naming it")
    func pathAtPathMaxIsRefused() throws {
        let destination = try makeDestination()
        let path = Array(repeating: String(repeating: "n", count: 200), count: 6).joined(separator: "/") + "/deep.txt"

        #expect(
            extractFailure(try rawArchive([.root(), .file(path, "deep"), .file("after.txt")]), into: destination)
                as? ClipboardItemFailure
                == ClipboardItemFailure(itemPath: path, reason: .posix(ENAMETOOLONG)))
    }

    /// APFS refuses the name; the failure names it as a display path, with
    /// the byte it could not store as U+FFFD.
    @Test("a name that is not UTF-8 is refused, naming it")
    func nameNotUTF8IsRefused() throws {
        let destination = try makeDestination()
        let archive = try rawArchive([
            .root(), .directory("dir"),
            RawArchiveEntry(
                type: .regularFile, path: Array("dir/caf".utf8) + [0xE9] + Array(".txt".utf8),
                mode: 0o644, data: Data("x".utf8)),
        ])

        #expect(
            extractFailure(archive, into: destination) as? ClipboardItemFailure
                == ClipboardItemFailure(itemPath: "dir/caf\u{FFFD}.txt", reason: .posix(EILSEQ)))
    }

    @Test("a refused entry stops the extract there: what came before lands, and nothing after it does")
    func nothingLandsPastARefusal() throws {
        let destination = try makeDestination()
        let archive = try rawArchive([
            .root(), .file("before.txt", "before"),
            RawArchiveEntry(
                type: .directory, path: Array("caf".utf8) + [0xE9], mode: 0o755),
            .directory("later"), .file("later/after.txt", "after"),
        ])

        #expect(extractFailure(archive, into: destination) is ClipboardItemFailure)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["before.txt"])
        #expect(try Data(contentsOf: destination.appendingPathComponent("before.txt")) == Data("before".utf8))
    }

    // MARK: - Left out

    @Test("an entry left out lands none of the data it carries, and the entry after it lands whole")
    func leftOutEntryDataIsSkipped() throws {
        let destination = try makeDestination()
        let archive = try rawArchive([
            .root(),
            RawArchiveEntry(type: .fifo, path: Array("pipe".utf8), mode: 0o644, data: Data("left out".utf8)),
            .file("after.txt", "after"),
        ])

        #expect(extractFailure(archive, into: destination) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["after.txt"])
        #expect(try Data(contentsOf: destination.appendingPathComponent("after.txt")) == Data("after".utf8))
    }

    // MARK: - Flags

    private static let creation = timespec(tv_sec: 981_173_106, tv_nsec: 111_111_111)
    private static let modification = timespec(tv_sec: 1_013_000_000, tv_nsec: 222_222_222)

    @Test(
        "a flag the receiver cannot set is withheld, and the entry keeps its mode and times",
        arguments: [UInt64(SF_ARCHIVED), UInt64(UF_DATAVAULT)])
    func unsettableFlagKeepsModeAndTimes(flag: UInt64) throws {
        let destination = try makeDestination()
        let archive = try rawArchive([
            .root(),
            RawArchiveEntry(
                type: .regularFile, path: Array("kept.txt".utf8), mode: 0o750, flags: flag,
                creation: Self.creation, modification: Self.modification, data: Data("x".utf8)),
        ])

        #expect(extractFailure(archive, into: destination) == nil)
        let status = try linkStatus(destination.appendingPathComponent("kept.txt").path)
        #expect(status.st_mode & 0o7777 == 0o750)
        #expect(sameInstant(status.st_mtimespec, Self.modification))
        #expect(sameInstant(status.st_birthtimespec, Self.creation))
        #expect(status.st_flags & UInt32(flag) == 0)
    }
}
