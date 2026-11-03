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
        let parent = try bench.fileSystem.openDirectory(bytes(bench.sourcePath), in: AT_FDCWD)
        defer { bench.fileSystem.close(parent) }
        let reader = try TreeReader(
            fileSystem: bench.fileSystem, item: name, in: parent,
            accepting: ContainerAcceptance(storage: .file, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false))
        _ = try reader.next()
        _ = try reader.next()
        try #require(withPath(bench.path([name])) { truncate($0, 1000) } == 0)
        let expected = TreeReadFailure(path: [name], reason: .changed)
        #expect(throws: expected) { while try reader.next() != nil {} }
        #expect(throws: expected) { try reader.next() }
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
                == TreeReadFailure(path: [bytes("item"), bytes("far")], reason: .notCarried(.symlinkTarget)))
    }
    #endif

    #if canImport(Darwin)
    @Test("a resource fork that fits a header record travels; a larger one fails the read naming its file")
    func resourceForkLimit() throws {
        let bench = try FidelityBench()
        let fits = Array(randomBytes(60 << 10, seed: 2))
        try bench.makeDirectory([bytes("item")])
        try bench.makeFile([bytes("item"), bytes("fits")], Data("data fork".utf8))
        try bench.setExtendedAttribute([bytes("item"), bytes("fits")], "com.apple.ResourceFork", fits)
        let landed = try bench.roundTrip(bytes("item"), accepting: Self.folder, policy: .never)
        let facts = try bench.facts(of: landed, in: bench.destinationPath)
        #expect(facts[[bytes("item"), bytes("fits")]]?.carriedXattrs[bytes("com.apple.ResourceFork")] == fits)

        try bench.makeDirectory([bytes("large")])
        try bench.makeFile([bytes("large"), bytes("icon")], Data())
        try bench.setExtendedAttribute(
            [bytes("large"), bytes("icon")], "com.apple.ResourceFork", Array(randomBytes(70 << 10, seed: 3)))
        let failure = try Self.failure("large", on: bench)
        #expect(
            failure == TreeReadFailure(path: [bytes("large"), bytes("icon")], reason: .notCarried(.metadataTooLarge)))
        #expect(failure?.wireError.code == .tooLarge)
        #expect(failure?.wireError.limit == UInt64(ContainerRecord.maxHeaderPayload))
    }
    #endif
}
#endif
