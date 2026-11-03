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
        try writer.write(.enterDirectory(directory(depth: 0)))
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
        try writer.write(.enterDirectory(directory(depth: 0)))
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
            let failure = Self.failure(writing: [.enterDirectory(directory(depth: 0)), event], to: writer)
            #expect(failure == TreeWriteFailure(path: [bytes("r"), name], reason: .container(.invalidName)))
            try landing.expectNothingOutside()
        }
    }

    @Test("the writer places by its own stack: a depth that disagrees with it is refused", arguments: bothLayers)
    func writerRefusesDepthJumps(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let writer = try landing.writer()
        let failure = Self.failure(
            writing: [.enterDirectory(directory(depth: 0)), .beginFile(file("f", depth: 2, size: 0))],
            to: writer)
        #expect(
            failure
                == TreeWriteFailure(
                    path: [bytes("r"), bytes("f")],
                    reason: .container(.depthBeyondParent(depth: 2, enteredDirectories: 1))))
        try landing.expectNothingOutside()
    }

    @Test("events out of order are refused: bytes with no file, a leave past the root, a second root, a symlink root")
    func writerRefusesOutOfOrderEvents() throws {
        let landing = try Landing(kernelContainment: true)
        let root = TreeEvent.enterDirectory(directory(depth: 0))
        let cases: [([TreeEvent], ContainerError)] = [
            ([root, .bytes(Data("x".utf8))], .chunkOutsideEntry),
            ([root, .finishFile], .eventOutOfOrder),
            ([root, .resourceFork], .eventOutOfOrder),
            ([root, .leaveDirectory, .leaveDirectory], .eventOutOfOrder),
            ([root, .end], .eventOutOfOrder),
            ([root, .leaveDirectory, .enterDirectory(directory(depth: 0))], .secondRootEntry),
            (
                [root, .enterDirectory(directory("d", depth: 1)), .beginFile(file("f", depth: 1, size: 0))],
                .directoryNotLeft(depth: 1, enteredDirectories: 2)
            ),
            ([root, .beginFile(directory("d", depth: 1))], .eventTypeMismatch(.directory)),
            ([.symlink(symlinkEntry(depth: 0, target: "t"))], .rootTypeMismatch(.symlink, expected: .folder)),
            ([.end], .noEntry),
        ]
        for (events, error) in cases {
            let failure = Self.failure(writing: events, to: try landing.writer())
            #expect(failure?.reason == .container(error), "\(events)")
            try landing.expectNothingOutside()
        }
    }

    @Test(
        "a file's bytes must match its declared size, its sizes the ceiling, and its storage one the writer lands",
        arguments: bothLayers)
    func writerHoldsSizes(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let root = TreeEvent.enterDirectory(directory(depth: 0))
        let f = [bytes("r"), bytes("f")]
        for size in [UInt64(2), largeFileSize] {
            let past = Self.failure(
                writing: [root, .beginFile(file("f", depth: 1, size: size)), .zeros(size + 1)],
                to: try landing.writer())
            #expect(
                past
                    == TreeWriteFailure(
                        path: f, reason: .container(.chunkPastEntrySize(count: size + 1, remaining: size))))
            let short = Self.failure(
                writing: [root, .beginFile(file("f", depth: 1, size: size)), .zeros(size - 1), .finishFile],
                to: try landing.writer())
            #expect(short == TreeWriteFailure(path: f, reason: .container(.entryIncomplete(remaining: 1))))
        }
        let ceiling = Self.failure(
            writing: [root, .beginFile(file("f", depth: 1, size: 11))], to: try landing.writer(ceiling: 10))
        #expect(
            ceiling == TreeWriteFailure(path: f, reason: .container(.exceedsByteCeiling(declared: 11, ceiling: 10))))
        #expect(ceiling?.wireError.code == .tooLarge)
        #expect(ceiling?.wireError.limit == 10)
        let decmpfs = compressedFile("f", depth: 1, type: 4, logicalSize: 1, resourceForkSize: 1)
        let compressed = Self.failure(writing: [root, .beginFile(decmpfs)], to: try landing.writer())
        #expect(compressed == TreeWriteFailure(path: f, reason: .container(.decmpfsTypeNotAccepted(4))))
        #expect(compressed?.wireError.code == .itemDecmpfsRefused)
        let forkCeiling = Self.failure(
            writing: [root, .beginFile(withResourceFork(file("f", depth: 1, size: 6), size: 5))],
            to: try landing.writer(ceiling: 10))
        #expect(
            forkCeiling == TreeWriteFailure(path: f, reason: .container(.exceedsByteCeiling(declared: 11, ceiling: 10)))
        )
        try landing.expectNothingOutside()
    }

    @Test("a resource fork's bytes follow its data's, after the event that starts them", arguments: bothLayers)
    func resourceForkOrder(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let root = TreeEvent.enterDirectory(directory(depth: 0))
        let f = [bytes("r"), bytes("f")]
        for size in [UInt64(2), largeFileSize] {
            let forked = TreeEvent.beginFile(withResourceFork(file("f", depth: 1, size: size), size: 3))
            let early = Self.failure(
                writing: [root, forked, .zeros(size - 1), .resourceFork], to: try landing.writer())
            #expect(early == TreeWriteFailure(path: f, reason: .container(.entryIncomplete(remaining: 1))))
            let missing = Self.failure(writing: [root, forked, .zeros(size), .finishFile], to: try landing.writer())
            #expect(missing == TreeWriteFailure(path: f, reason: .container(.entryIncomplete(remaining: 3))))
            let past = Self.failure(
                writing: [root, forked, .zeros(size), .resourceFork, .zeros(4)], to: try landing.writer())
            #expect(past == TreeWriteFailure(path: f, reason: .container(.chunkPastEntrySize(count: 4, remaining: 3))))
            let twice = Self.failure(
                writing: [root, forked, .zeros(size), .resourceFork, .resourceFork], to: try landing.writer())
            #expect(twice == TreeWriteFailure(path: f, reason: .container(.eventOutOfOrder)))
        }
        let unforked = Self.failure(
            writing: [root, .beginFile(file("f", depth: 1, size: 1)), .zeros(1), .resourceFork],
            to: try landing.writer())
        #expect(unforked == TreeWriteFailure(path: f, reason: .container(.resourceForkUndeclared)))
        let onDirectory = Self.failure(
            writing: [root, .enterDirectory(withResourceFork(directory("d", depth: 1), size: 1))],
            to: try landing.writer())
        #expect(
            onDirectory
                == TreeWriteFailure(
                    path: [bytes("r"), bytes("d")], reason: .container(.resourceForkNotAllowed(.directory))))
        try landing.expectNothingOutside()
    }

    @Test("a resource fork lands where the OS keeps one, and is left out, the data landing whole, where it keeps none")
    func resourceForkLandsOrIsLeftOut() throws {
        let landing = try Landing(kernelContainment: true)
        let writer = try landing.writer()
        let fork = pattern(Int(largeFileSize), seed: 9)
        for event in [
            TreeEvent.enterDirectory(directory(depth: 0)),
            .beginFile(withResourceFork(file("held", depth: 1, size: 4), size: 3)), .bytes(Data("data".utf8)),
            .resourceFork, .bytes(Data("ico".utf8)), .finishFile,
            .beginFile(withResourceFork(file("written", depth: 1, size: largeFileSize), size: largeFileSize)),
            .bytes(pattern(Int(largeFileSize))), .resourceFork, .bytes(fork), .finishFile, .leaveDirectory, .end,
        ] {
            try writer.write(event)
        }
        #expect(try writer.publish() == bytes("r"))
        let directory = try landing.fileSystem.openDirectory(bytes(landing.destinationPath + "/r"), in: AT_FDCWD)
        defer { landing.fileSystem.close(directory) }
        for (name, expected) in [("held", Data("ico".utf8)), ("written", fork)] {
            let descriptor = try landing.fileSystem.openFile(bytes(name), in: directory)
            defer { landing.fileSystem.close(descriptor) }
            let size = try landing.fileSystem.resourceForkSize(of: descriptor, showingCompression: false)
            #if canImport(Darwin)
            var read = [UInt8](repeating: 0, count: Int(size))
            var offset = 0
            while offset < read.count {
                offset += try read.withUnsafeMutableBytes { buffer in
                    try landing.fileSystem.readResourceFork(
                        descriptor, into: UnsafeMutableRawBufferPointer(rebasing: buffer[offset...]),
                        at: UInt64(offset), showingCompression: false)
                }
            }
            #expect(Data(read) == expected, "the fork of \(name)")
            #else
            #expect(size == 0, "\(name) holds none of its \(expected.count)-byte fork on Linux")
            #endif
        }
        #expect(try landing.landedEntries(bytes("r")).contains("./written: regular \(largeFileSize)"))
    }

    @Test(
        "a tree written as events lands only once published, under the name the writer was given", arguments: bothLayers
    )
    func eventsLandOnlyWhenPublished(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let writer = try landing.writer(as: bytes("Given Name"))
        for event in [
            TreeEvent.enterDirectory(directory(depth: 0)), .beginFile(file("f", depth: 1, size: 1)),
            .bytes(Data("f".utf8)), .finishFile, .leaveDirectory, .end,
        ] {
            try writer.write(event)
        }
        let staged = String(decoding: writer.stagingName, as: UTF8.self)
        #expect(try landing.entriesOutside(landed: writer.stagingName).count == 3)
        #expect(try landing.landedEntries(writer.stagingName) == [".: directory", "./f: regular 1"].sorted())
        #expect(staged.hasPrefix(".kernova-"))
        #expect(try writer.publish() == bytes("Given Name"))
        #expect(try landing.landedEntries(bytes("Given Name")) == [".: directory", "./f: regular 1"].sorted())
        try landing.expectNothingOutside(landed: bytes("Given Name"))
    }

    @Test("a writer that ends unpublished removes what it created")
    func abandonedWriterRemovesItsTree() throws {
        let landing = try Landing(kernelContainment: true)
        do {
            let writer = try landing.writer()
            try writer.write(.enterDirectory(directory(depth: 0)))
            try writer.write(.beginFile(file("f", depth: 1, size: largeFileSize)))
            try writer.write(.bytes(pattern(100)))
        }
        try landing.expectNothingOutside()
    }
}

#endif
