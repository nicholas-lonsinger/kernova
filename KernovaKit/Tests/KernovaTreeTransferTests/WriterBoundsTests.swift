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
import KernovaLogging
import KernovaSynchronization
import KernovaWire
import Testing

@testable import KernovaTreeTransfer

/// What the writer and receiver cost and refuse whatever drives them: the entry rules every producer is held
/// to, linear time and owned memory for held files, nothing taken after a failure, and a failure that names
/// the item to the end.
@Suite("Writer bounds and rules")
struct WriterBoundsTests {
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

    private static func xattr(_ name: [UInt8], _ value: String = "v") -> Kernova_V2_Xattr {
        var attribute = Kernova_V2_Xattr()
        attribute.name = Data(name)
        attribute.value = Data(value.utf8)
        return attribute
    }

    /// A header breaking one entry rule, and the rule.
    struct Breach: Sendable, CustomTestStringConvertible {
        let label: String
        let change: @Sendable (inout EntryHeader) -> Void
        let rule: ContainerError

        var testDescription: String { label }
    }

    static let breaches: [Breach] = [
        Breach(label: "UF_IMMUTABLE", change: { $0.darwinFlags = 0x2 }, rule: .darwinFlagsNotAllowed(0x2)),
        Breach(label: "UF_APPEND", change: { $0.darwinFlags = 0x4 }, rule: .darwinFlagsNotAllowed(0x4)),
        Breach(
            label: "UF_COMPRESSED", change: { $0.darwinFlags = 0x20 | 0x8000 }, rule: .darwinFlagsNotAllowed(0x20)),
        Breach(
            label: "com.apple.decmpfs", change: { $0.xattrs = [xattr(Array("com.apple.decmpfs".utf8))] },
            rule: .xattrNotAllowed(Data("com.apple.decmpfs".utf8))),
        Breach(
            label: "com.apple.quarantine", change: { $0.xattrs = [xattr(Array("com.apple.quarantine".utf8))] },
            rule: .xattrNotAllowed(Data("com.apple.quarantine".utf8))),
        Breach(
            label: "xattr name with NUL", change: { $0.xattrs = [xattr(Array("user.a".utf8) + [0, 0x62])] },
            rule: .invalidXattrName),
        Breach(label: "mode past 07777", change: { $0.mode = 0o170_644 }, rule: .modeOutOfRange(0o170_644)),
        Breach(
            label: "nanoseconds past 999,999,999", change: { $0.modificationTime.nanoseconds = 2_500_000_000 },
            rule: .nanosecondsOutOfRange(2_500_000_000)),
        Breach(
            label: "birth nanoseconds past 999,999,999", change: { $0.birthTime.nanoseconds = 1_000_000_000 },
            rule: .nanosecondsOutOfRange(1_000_000_000)),
    ]

    @Test(
        "a producer driving the writer directly is held to the container's entry rules, on every entry type",
        arguments: breaches)
    func writerHoldsEntryRules(breach: Breach) throws {
        let landing = try Landing(kernelContainment: true)
        var root = directory("r", depth: 0)
        breach.change(&root)
        #expect(
            Self.failure(writing: [.enterDirectory(root)], to: try landing.writer())
                == TreeWriteFailure(path: [bytes("r")], reason: .event(.invalidEntry(breach.rule))))
        var rootFile = file("f", depth: 0, size: 1)
        breach.change(&rootFile)
        #expect(
            Self.failure(writing: [.beginFile(rootFile)], to: try landing.writer())
                == TreeWriteFailure(path: [bytes("f")], reason: .event(.invalidEntry(breach.rule))))
        for var child in [
            file("c", depth: 1, size: 1), file("c", depth: 1, size: largeFileSize), directory("c", depth: 1),
            symlinkEntry("c", depth: 1, target: "t"),
        ] {
            breach.change(&child)
            let event: TreeEvent =
                switch child.type {
                case .directory: .enterDirectory(child)
                case .symlink: .symlink(child)
                default: .beginFile(child)
                }
            #expect(
                Self.failure(writing: [.enterDirectory(directory("r", depth: 0)), event], to: try landing.writer())
                    == TreeWriteFailure(path: [bytes("r"), bytes("c")], reason: .event(.invalidEntry(breach.rule))))
        }
        try landing.expectNothingOutside()
    }

    @Test("a symlink's target must be one the format carries")
    func writerHoldsSymlinkTargets() throws {
        let landing = try Landing(kernelContainment: true)
        for target in [Data(), Data("a\0b".utf8), Data(repeating: 0x61, count: 1024)] {
            var link = symlinkEntry("s", depth: 1, target: "t")
            link.symlinkTarget = target
            #expect(
                Self.failure(writing: [.enterDirectory(directory("r", depth: 0)), .symlink(link)], to: try landing.writer())
                    == TreeWriteFailure(
                        path: [bytes("r"), bytes("s")], reason: .event(.invalidEntry(.invalidSymlinkTarget))))
        }
        try landing.expectNothingOutside()
    }

    @Test("zero-length bytes and zeros are refused, held or written", arguments: [UInt64(3), largeFileSize])
    func emptyPiecesAreRefused(size: UInt64) throws {
        let landing = try Landing(kernelContainment: true)
        for piece in [TreeEvent.bytes(Data()), .zeros(0)] {
            #expect(
                Self.failure(
                    writing: [.enterDirectory(directory("r", depth: 0)), .beginFile(file("f", depth: 1, size: size)), piece],
                    to: try landing.writer())
                    == TreeWriteFailure(path: [bytes("r"), bytes("f")], reason: .event(.emptyPiece)))
        }
        try landing.expectNothingOutside()
    }

    @Test("a held file's bytes are copied into storage of their own, keeping none of the producer's buffer")
    func heldBytesAreOwned() throws {
        let landing = try Landing(kernelContainment: true)
        let writer = try landing.writer()
        let buffer = pattern(1 << 20)
        try writer.write(.enterDirectory(directory("r", depth: 0)))
        try writer.write(.beginFile(file("f", depth: 1, size: 3)))
        try writer.write(.bytes(buffer[1000..<1002]))
        try writer.write(.zeros(1))
        try writer.write(.finishFile)
        guard case .file(let held) = try #require(writer.batch.entries.first).content else {
            Issue.record("the file was not held")
            return
        }
        #expect(held == buffer[1000..<1002] + Data([0]))
        let heldRange = held.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        let bufferRange = buffer.withUnsafeBytes {
            UInt(bitPattern: $0.baseAddress)..<(UInt(bitPattern: $0.baseAddress) + UInt($0.count))
        }
        #expect(!bufferRange.contains(heldRange))
    }

    @Test("a held file arriving a byte at a time costs no more than a written one")
    func heldFilesCostLinearTime() throws {
        let landing = try Landing(kernelContainment: true)
        let pieces = 65_536
        var container = RawContainer()
        container.header(directory("r", depth: 0))
        container.header(file("held", depth: 1, size: UInt64(pieces)))
        for _ in 0..<pieces { container.chunk(Data([0x41])) }
        container.header(file("written", depth: 1, size: largeFileSize + UInt64(pieces)))
        container.zeros(largeFileSize)
        for _ in 0..<pieces { container.chunk(Data([0x42])) }
        container.end()
        let receiver = try landing.receiver(acceptance())
        let data = container.data
        let (heldStart, heldEnd) = (container.boundaries[2], container.boundaries[2 + pieces])
        let writtenStart = container.boundaries[3 + pieces]
        let clock = ContinuousClock()
        try receiver.receive(data[..<heldStart])
        let held = try clock.measure { try receiver.receive(data[heldStart..<heldEnd]) }
        try receiver.receive(data[heldEnd..<writtenStart])
        let written = try clock.measure { try receiver.receive(data[writtenStart...]) }
        #expect(try receiver.finish() == bytes("r"))
        // Quadratic, the held file took 358 s in a release build at 256 KiB, about 22 s at this size.
        #expect(held < written * 4 + .seconds(1), "held \(held), written \(written)")
    }

    @Test("once a receive has failed, the receiver takes no more bytes, whichever side failed")
    func failedReceiverHoldsNothing() throws {
        let landing = try Landing(kernelContainment: true)
        var block = RawContainer()
        block.header(directory("d", depth: 1))
        let more = Data(repeating: block.data[0], count: 1) + block.data.dropFirst()

        var decoderFails = RawContainer()
        decoderFails.header(directory("r", depth: 0))
        decoderFails.header(directory("r", depth: 0))
        try #require(mkdir(landing.destinationPath + "/r", 0o755) == 0)
        var writerFails = RawContainer()
        writerFails.header(directory("r", depth: 0))
        writerFails.end()
        for (container, finishes) in [(decoderFails.data, false), (writerFails.data, true)] {
            let receiver = try landing.receiver(acceptance())
            let first = Result { () throws(TreeWriteFailure) in
                try receiver.receive(container)
                _ = try receiver.finish()
            }
            let failure = try #require(first.failure, "finishes: \(finishes)")
            for _ in 0..<16 {
                let again = Result { () throws(TreeWriteFailure) in try receiver.receive(more) }
                #expect(again.failure == failure)
            }
            #expect(receiver.heldByteCount == 0)
            #expect(Result { () throws(TreeWriteFailure) in try receiver.finish() }.failure == failure)
        }
    }

    @Test("a failure after the item's own entry has begun names the item")
    func lateFailuresNameTheItem() throws {
        let landing = try Landing(kernelContainment: true)
        var truncatedFile = RawContainer()
        truncatedFile.file(file("report", depth: 0, size: 5), Data("hello".utf8))
        #expect(
            try landing.land(truncatedFile.data, accepting: acceptance(.file)).failure
                == TreeWriteFailure(path: [bytes("report")], reason: .container(.truncated)))

        var miscounted = truncatedFile
        var end = EndRecord()
        end.entries = 7
        end.bytes = 5
        miscounted.record(.end, RawContainer.serialized(end))
        #expect(
            try landing.land(miscounted.data, accepting: acceptance(.file)).failure?.path == [bytes("report")])

        var folder = RawContainer()
        folder.header(directory("r", depth: 0))
        folder.file(file("f", depth: 1, size: 1), Data("x".utf8))
        folder.end()
        #expect(
            try landing.land(folder.data + Data([ContainerRecordKind.chunk.rawValue])).failure
                == TreeWriteFailure(path: [bytes("r")], reason: .container(.bytesAfterEnd)))

        let afterEnd = Self.failure(
            writing: [.enterDirectory(directory("r", depth: 0)), .leaveDirectory, .end, .end],
            to: try landing.writer())
        #expect(afterEnd == TreeWriteFailure(path: [bytes("r")], reason: .event(.outOfOrder)))
        try landing.expectNothingOutside()
    }

    @Test("a staging root the writer cannot remove is reported, not dropped")
    func removalFailuresAreLogged() throws {
        let landing = try Landing(kernelContainment: true)
        let logged = Locked<[String]>([])
        let logger = KernovaLogger(subsystem: "app.kernova", category: "TreeWriterTests") { level, _, _, segments in
            logged.withLock { $0.append("\(level): " + segments.map(\.text).joined()) }
        }
        let writer = try landing.writer(logger: logger)
        try writer.write(.enterDirectory(directory("r", depth: 0)))
        let staging = landing.destinationPath + "/" + String(decoding: writer.stagingName, as: UTF8.self)
        try #require(rename(staging, landing.destinationPath + "/moved") == 0)
        #expect(Self.failure(writing: [.leaveDirectory, .leaveDirectory], to: writer)?.reason == .event(.outOfOrder))
        let lines = logged.withLock { $0 }
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("error: Could not remove the staging root .kernova-") == true, "\(lines)")
    }
}
#endif
