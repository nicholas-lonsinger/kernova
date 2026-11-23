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
}
#endif
