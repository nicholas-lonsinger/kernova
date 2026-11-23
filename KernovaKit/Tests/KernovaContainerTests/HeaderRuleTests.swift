#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaWire
import SwiftProtobuf
import Testing

private func xattr(_ attributeName: Data, _ value: Data = Data([1])) -> Kernova_V2_Xattr {
    var xattr = Kernova_V2_Xattr()
    xattr.name = attributeName
    xattr.value = value
    return xattr
}

@Suite("The byte ceiling bounds landed bytes")
struct LandedCeilingTests {
    static func decmpfs(logical: UInt64, fork: UInt64, ceiling: UInt64) -> ContainerError? {
        let acceptance = ContainerAcceptance(storage: .file, byteCeiling: ceiling, decmpfsTypes: [4], acceptsLZ4: false)
        let header = decmpfsFile(
            depth: 0, attribute: decmpfsAttribute(type: 4, size: logical), resourceForkSize: fork)
        var container = headerRecord(header)
        if fork > 0 { container += record(.chunk, Data(repeating: 1, count: Int(fork))) }
        return decodingError(container + endRecord(entries: 1, bytes: fork), accepting: acceptance)
    }

    @Test("A resource fork larger than the logical size counts in its place")
    func forkCounts() {
        #expect(Self.decmpfs(logical: 1, fork: 100, ceiling: 100) == nil)
        #expect(Self.decmpfs(logical: 1, fork: 101, ceiling: 100) == .exceedsByteCeiling(declared: 101, ceiling: 100))
    }
}

@Suite("Unknown protobuf fields make a record malformed")
struct UnknownFieldTests {
    static let file = serialized(plainFile(depth: 0, size: 0))
    static let end = endRecord(entries: 1, bytes: 0)

    @Test("Deeply nested unknown groups in a header are refused without a crash")
    func nestedGroups() {
        let depth = 30_000
        let payload = Data(repeating: 0x7B, count: depth) + Data(repeating: 0x7C, count: depth)
        #expect(decodingError(record(.header, payload) + Self.end, accepting: generous(.file)) != nil)
    }
}
