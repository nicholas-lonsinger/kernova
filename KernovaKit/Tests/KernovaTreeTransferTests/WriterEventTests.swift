#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import KernovaContainer
import KernovaFileTree
import KernovaWire
import Testing

@testable import KernovaTreeTransfer

/// The writer driven by events directly: what no container can express — a directory swapped while the
/// writer is inside it — and the rules the writer holds every producer to, whatever its decoder let through.
@Suite("Writer events")
struct WriterEventTests {
    /// Writes `events`, returning the first failure.
    private static func failure(
        writing events: [TreeEvent], to writer: TreeWriter<POSIXTreeFileSystem>
    ) -> TreeWriteFailure? {
        do {
            for event in events { try writer.write(event) }
            return nil
        } catch {
            return error
        }
    }

    /// Renames `name` in the staging root to `name.moved`, and with `link` puts a symlink to the outside
    /// directory in its place.
    private static func swap(
        _ name: String, in landing: Landing, writer: TreeWriter<POSIXTreeFileSystem>, link: Bool
    ) throws {
        let staging = landing.destinationPath + "/" + String(decoding: writer.stagingName, as: UTF8.self)
        try #require(rename(staging + "/" + name, staging + "/" + name + ".moved") == 0)
        if link { try #require(symlink(landing.outsidePath, staging + "/" + name) == 0) }
    }

    /// How the entered directory is swapped, and how large the file then written into it is.
    enum Swap: CaseIterable, Sendable {
        case renamedThenSmallFile, renamedThenLargeFile, linkedThenSmallFile, linkedThenLargeFile

        var link: Bool { self == .linkedThenSmallFile || self == .linkedThenLargeFile }
        var size: UInt64 { self == .renamedThenSmallFile || self == .linkedThenSmallFile ? 3 : largeFileSize }
    }

    @Test(
        "an entered directory renamed or replaced by a symlink mid-transfer takes no entry outside, and fails as it is left",
        arguments: bothLayers, Swap.allCases)
    func swappedDirectoryIsCaught(kernelContainment: Bool, swap: Swap) throws {
        let (link, size) = (swap.link, swap.size)
        let landing = try Landing(kernelContainment: kernelContainment)
        let writer = try landing.writer()
        try writer.write(.enterDirectory(directory("r", depth: 0)))
        try writer.write(.enterDirectory(directory("a", depth: 1)))
        try Self.swap("a", in: landing, writer: writer, link: link)
        let failure = Self.failure(
            writing: [
                .beginFile(file("f", depth: 2, size: size)), .bytes(pattern(Int(size))), .finishFile,
                .enterDirectory(directory("b", depth: 2)), .leaveDirectory, .leaveDirectory,
            ], to: writer)
        #expect(failure == TreeWriteFailure(path: [bytes("r"), bytes("a")], reason: .moved))
        try landing.expectNothingOutside()
    }

    @Test(
        "a directory swapped above the one the writer is in fails as the writer climbs past it", arguments: bothLayers)
    func swappedAncestorIsCaught(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let writer = try landing.writer()
        try writer.write(.enterDirectory(directory("r", depth: 0)))
        try writer.write(.enterDirectory(directory("a", depth: 1)))
        try writer.write(.enterDirectory(directory("b", depth: 2)))
        try Self.swap("a", in: landing, writer: writer, link: true)
        let failure = Self.failure(
            writing: [
                .beginFile(file("f", depth: 3, size: 1)), .bytes(Data("f".utf8)), .finishFile, .leaveDirectory,
                .leaveDirectory,
            ], to: writer)
        #expect(failure == TreeWriteFailure(path: [bytes("r"), bytes("a")], reason: .moved))
        try landing.expectNothingOutside()
    }

    @Test(
        "the writer refuses an invalid name itself, whatever produced it",
        arguments: bothLayers, HostileContainerTests.invalidNames)
    func writerRefusesInvalidNames(kernelContainment: Bool, name: [UInt8]) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        for event in [
            TreeEvent.beginFile(file(name, depth: 1, size: 0)), .enterDirectory(directory(name, depth: 1)),
            .symlink(
                {
                    var header = symlinkEntry("x", depth: 1, target: "t")
                    header.name = Data(name)
                    return header
                }()),
        ] {
            let writer = try landing.writer()
            let failure = Self.failure(writing: [.enterDirectory(directory("r", depth: 0)), event], to: writer)
            #expect(failure == TreeWriteFailure(path: [bytes("r"), name], reason: .event(.invalidEntry(.invalidName))))
            try landing.expectNothingOutside()
        }
    }

    @Test("the writer places by its own stack: a depth that disagrees with it is refused", arguments: bothLayers)
    func writerRefusesDepthJumps(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let writer = try landing.writer()
        let failure = Self.failure(
            writing: [.enterDirectory(directory("r", depth: 0)), .beginFile(file("f", depth: 2, size: 0))],
            to: writer)
        #expect(
            failure
                == TreeWriteFailure(
                    path: [bytes("r"), bytes("f")], reason: .event(.depthMismatch(depth: 2, entered: 1))))
        try landing.expectNothingOutside()
    }

    @Test("events out of order are refused: bytes with no file, a leave past the root, a second root, a symlink root")
    func writerRefusesOutOfOrderEvents() throws {
        let landing = try Landing(kernelContainment: true)
        let cases: [[TreeEvent]] = [
            [.enterDirectory(directory("r", depth: 0)), .bytes(Data("x".utf8))],
            [.enterDirectory(directory("r", depth: 0)), .finishFile],
            [.enterDirectory(directory("r", depth: 0)), .leaveDirectory, .leaveDirectory],
            [.enterDirectory(directory("r", depth: 0)), .leaveDirectory, .enterDirectory(directory("s", depth: 0))],
            [.symlink(symlinkEntry("s", depth: 0, target: "t"))],
            [.end],
        ]
        for events in cases {
            let failure = Self.failure(writing: events, to: try landing.writer())
            #expect(failure?.reason == .event(.outOfOrder), "\(events)")
            try landing.expectNothingOutside()
        }
    }

    @Test(
        "a file's bytes must match its declared size, its sizes the ceiling, and its storage one the writer lands",
        arguments: bothLayers)
    func writerHoldsSizes(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let root = TreeEvent.enterDirectory(directory("r", depth: 0))
        let f = [bytes("r"), bytes("f")]
        for size in [UInt64(2), largeFileSize] {
            let past = Self.failure(
                writing: [root, .beginFile(file("f", depth: 1, size: size)), .zeros(size + 1)],
                to: try landing.writer())
            #expect(past == TreeWriteFailure(path: f, reason: .event(.sizeMismatch(declared: size, carried: size + 1))))
            let short = Self.failure(
                writing: [root, .beginFile(file("f", depth: 1, size: size)), .zeros(size - 1), .finishFile],
                to: try landing.writer())
            #expect(
                short == TreeWriteFailure(path: f, reason: .event(.sizeMismatch(declared: size, carried: size - 1))))
        }
        let ceiling = Self.failure(
            writing: [root, .beginFile(file("f", depth: 1, size: 11))], to: try landing.writer(ceiling: 10))
        #expect(ceiling == TreeWriteFailure(path: f, reason: .event(.exceedsByteCeiling(10))))
        var decmpfs = file("f", depth: 1, size: 0)
        decmpfs.decmpfs.attribute = Data(count: 16)
        let compressed = Self.failure(writing: [root, .beginFile(decmpfs)], to: try landing.writer())
        #expect(compressed == TreeWriteFailure(path: f, reason: .event(.decmpfsNotLanded)))
        #expect(compressed?.wireError.code == .itemDecmpfsRefused)
        try landing.expectNothingOutside()
    }

    @Test("a tree written as events lands only once published", arguments: bothLayers)
    func eventsLandOnlyWhenPublished(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let writer = try landing.writer()
        for event in [
            TreeEvent.enterDirectory(directory("r", depth: 0)), .beginFile(file("f", depth: 1, size: 1)),
            .bytes(Data("f".utf8)), .finishFile, .leaveDirectory, .end,
        ] {
            try writer.write(event)
        }
        let staged = String(decoding: writer.stagingName, as: UTF8.self)
        #expect(try landing.entriesOutside(landed: writer.stagingName).count == 3)
        #expect(try landing.landedEntries(writer.stagingName) == [".: directory", "./f: regular 1"].sorted())
        #expect(staged.hasPrefix(".kernova-"))
        #expect(try writer.publish() == bytes("r"))
        #expect(try landing.landedEntries(bytes("r")) == [".: directory", "./f: regular 1"].sorted())
        try landing.expectNothingOutside(landed: bytes("r"))
    }

    @Test("a writer that ends unpublished removes what it created")
    func abandonedWriterRemovesItsTree() throws {
        let landing = try Landing(kernelContainment: true)
        do {
            let writer = try landing.writer()
            try writer.write(.enterDirectory(directory("r", depth: 0)))
            try writer.write(.beginFile(file("f", depth: 1, size: largeFileSize)))
            try writer.write(.bytes(pattern(100)))
        }
        try landing.expectNothingOutside()
    }
}

#endif
