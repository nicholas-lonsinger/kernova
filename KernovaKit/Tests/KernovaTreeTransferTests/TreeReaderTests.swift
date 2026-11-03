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

/// What the reader refuses to put in a container, naming the entry.
@Suite("Tree reader")
struct TreeReaderTests {
    private static let folder = ContainerAcceptance(
        storage: .folder, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false)

    /// The failure reading the item `name` comes to.
    private static func failure(
        _ name: String, on bench: FidelityBench, accepting acceptance: ContainerAcceptance = folder
    ) throws -> TreeReadFailure? {
        do {
            _ = try bench.events(bytes(name), accepting: acceptance)
            return nil
        } catch let failure as TreeReadFailure {
            return failure
        }
    }

    @Test("a FIFO, which the format has no entry for, fails the read naming it")
    func fifoRefused() throws {
        let bench = try FidelityBench()
        try bench.makeDirectory([bytes("item")])
        try #require(withPath(bench.path([bytes("item"), bytes("pipe")])) { mkfifo($0, 0o644) } == 0)
        let failure = try Self.failure("item", on: bench)
        #expect(failure == TreeReadFailure(path: [bytes("item"), bytes("pipe")], reason: .notCarried(.type(.fifo))))
        #expect(failure?.wireError.code == .readFailed)
    }

    @Test(
        "an item is opened by its own path, so a folder above it that cannot be opened does not stop it",
        .enabled(if: geteuid() != 0, "root reads past every permission bit, as the Linux CI container runs"))
    func rootOpenedByItsOwnPath() throws {
        let bench = try FidelityBench()
        try bench.makeDirectory([bytes("locked")])
        try bench.makeDirectory([bytes("locked"), bytes("item")])
        try bench.makeFile([bytes("locked"), bytes("item"), bytes("a")], Data("a".utf8))
        let locked = String(decoding: bench.path([bytes("locked")]), as: UTF8.self)
        // Searchable, unreadable: the item's path resolves, and an open of the folder itself fails.
        try #require(chmod(locked, 0o111) == 0)
        defer { _ = chmod(locked, 0o755) }
        try #require(open(locked, O_RDONLY | O_DIRECTORY) == -1)
        let reader = try TreeReader(
            fileSystem: bench.fileSystem, root: bench.path([bytes("locked"), bytes("item")]), accepting: Self.folder)
        var events: [TreeEvent] = []
        while let event = try reader.next() { events.append(event) }
        #expect(events.last == .end)
        #expect(events.contains(.bytes(Data("a".utf8))))
    }

    @Test("a root that is no absolute path, or ends in no name, is refused before anything resolves it")
    func rootPathRefused() throws {
        let bench = try FidelityBench()
        for root in ["relative/item", "/", String(decoding: bench.path([]), as: UTF8.self) + "/"] {
            #expect(throws: TreeReadFailure.self, "\(root)") {
                try TreeReader(fileSystem: bench.fileSystem, root: bytes(root), accepting: Self.folder)
            }
        }
    }

    @Test("an item that is not what its storage names is refused")
    func rootTypeRefused() throws {
        let bench = try FidelityBench()
        try bench.makeDirectory([bytes("folder")])
        try bench.makeFile([bytes("file")], Data("x".utf8))
        let file = ContainerAcceptance(storage: .file, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false)
        #expect(
            try Self.failure("folder", on: bench, accepting: file)
                == TreeReadFailure(path: [bytes("folder")], reason: .notCarried(.rootType(.directory))))
        #expect(
            try Self.failure("file", on: bench)
                == TreeReadFailure(path: [bytes("file")], reason: .notCarried(.rootType(.regular))))
    }

    @Test("the file that takes the item past the byte ceiling fails the read, as too large")
    func ceilingRefused() throws {
        let bench = try FidelityBench()
        try bench.makeDirectory([bytes("item")])
        try bench.makeFile([bytes("item"), bytes("a")], Data(count: 600))
        try bench.makeFile([bytes("item"), bytes("b")], Data(count: 500))
        let ceiling = ContainerAcceptance(storage: .folder, byteCeiling: 1_000, decmpfsTypes: [], acceptsLZ4: false)
        let failure = try Self.failure("item", on: bench, accepting: ceiling)
        #expect(failure == TreeReadFailure(path: [bytes("item"), bytes("b")], reason: .exceedsByteCeiling(1_000)))
        #expect(failure?.wireError.code == .tooLarge)
        #expect(failure?.wireError.limit == 1_000)
    }

    @Test("a file cut short while it is read fails as changed, and the reader then only repeats the failure")
    func truncatedWhileRead() throws {
        let bench = try FidelityBench()
        let name = bytes("growing")
        try bench.makeFile([name], randomBytes(1 << 20, seed: 1))
        let reader = try TreeReader(
            fileSystem: bench.fileSystem, root: bench.path([name]),
            accepting: ContainerAcceptance(storage: .file, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false))
        _ = try reader.next()
        _ = try reader.next()
        try #require(withPath(bench.path([name])) { truncate($0, 1000) } == 0)
        let expected = TreeReadFailure(path: [name], reason: .changed)
        #expect(throws: expected) { while try reader.next() != nil {} }
        #expect(throws: expected) { try reader.next() }
    }

    @Test("the item's own header carries no name, whether it is a folder or a file; the entries in it carry theirs")
    func rootUnnamed() throws {
        let bench = try FidelityBench()
        try bench.makeDirectory([bytes("folder")])
        try bench.makeFile([bytes("folder"), bytes("a")], Data("a".utf8))
        try bench.makeFile([bytes("file")], Data("x".utf8))
        let folder = try bench.events(bytes("folder"), accepting: Self.folder)
        guard case .enterDirectory(let root)? = folder.first, case .beginFile(let child)? = folder.dropFirst().first
        else {
            Issue.record("events \(folder)")
            return
        }
        #expect(root.name.isEmpty)
        #expect(child.name == Data("a".utf8))
        let fileAcceptance = ContainerAcceptance(
            storage: .file, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false)
        guard case .beginFile(let file)? = try bench.events(bytes("file"), accepting: fileAcceptance).first else {
            Issue.record("no file entry")
            return
        }
        #expect(file.name.isEmpty)
    }

    @Test("every event the reader produces of a tree is one the encoder takes, and the tree decodes back whole")
    func eventsEncode() throws {
        let bench = try FidelityBench()
        _ = try RoundTripFidelityTests.buildTree(on: bench)
        let events = try bench.events(RoundTripFidelityTests.item, accepting: Self.folder)
        var encoder = ContainerEncoder(accepting: Self.folder, policy: .never)
        var container = Data()
        for event in events { container += try encoder.encode(event) }
        var decoder = ContainerDecoder(accepting: Self.folder)
        decoder.feed(container)
        var decoded: [TreeEvent] = []
        while let event = try decoder.next() { decoded.append(event) }
        try decoder.finish()
        #expect(decoded.count >= events.filter { if case .bytes = $0 { false } else { true } }.count)
        #expect(decoded.last == .end)
    }

    #if os(Linux)
    @Test("a symlink target longer than the format carries fails the read naming the link")
    func longTargetRefused() throws {
        let bench = try FidelityBench()
        try bench.makeDirectory([bytes("item")])
        try bench.makeSymlink([bytes("item"), bytes("far")], to: Array(repeating: 0x61, count: 2_000))
        #expect(
            try Self.failure("item", on: bench)
                == TreeReadFailure(
                    path: [bytes("item"), bytes("far")], reason: .notCarried(.entry(.invalidSymlinkTarget))))
    }
    #endif
}
#endif
