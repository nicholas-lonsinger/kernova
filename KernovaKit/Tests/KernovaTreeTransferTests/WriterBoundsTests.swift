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
        var root = directory(depth: 0)
        breach.change(&root)
        #expect(
            Self.failure(writing: [.enterDirectory(root)], to: try landing.writer())
                == TreeWriteFailure(path: [bytes("r")], reason: .container(breach.rule)))
        var rootFile = file(depth: 0, size: 1)
        breach.change(&rootFile)
        #expect(
            Self.failure(writing: [.beginFile(rootFile)], to: try landing.writer(.file, as: bytes("f")))
                == TreeWriteFailure(path: [bytes("f")], reason: .container(breach.rule)))
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
                Self.failure(writing: [.enterDirectory(directory(depth: 0)), event], to: try landing.writer())
                    == TreeWriteFailure(path: [bytes("r"), bytes("c")], reason: .container(breach.rule)))
        }
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
        try writer.write(.enterDirectory(directory(depth: 0)))
        let staging = landing.destinationPath + "/" + String(decoding: writer.stagingName, as: UTF8.self)
        try #require(rename(staging, landing.destinationPath + "/moved") == 0)
        #expect(
            Self.failure(writing: [.leaveDirectory, .leaveDirectory], to: writer)?.reason
                == .container(.eventOutOfOrder))
        let lines = logged.withLock { $0 }
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("error: Could not remove the staging root .kernova-") == true, "\(lines)")
    }
}
#endif
