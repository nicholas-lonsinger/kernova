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
