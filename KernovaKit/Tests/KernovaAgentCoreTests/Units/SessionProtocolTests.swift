#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import KernovaAgentCore
import KernovaDigest
import KernovaPortableTestSupport
import KernovaWire
import SwiftProtobuf
import Testing

extension CoreUnits {
    @Suite("Session protocol version")
    struct SessionProtocolTests {
        /// The digest of a schema's text as Tools/lib/proto-digest.sh defines it: every `//` comment removed, each run
        /// of whitespace one space, the ends trimmed; the first four bytes of its SHA-256, big-endian, top bit set.
        static func schemaDigest(_ text: Data) -> UInt32 {
            let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]
            let code = text.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
                line.firstRange(of: Data("//".utf8)).map { line[..<$0.lowerBound] } ?? line
            }
            let words = Data(code.joined(separator: [0x0A])).split(whereSeparator: whitespace.contains)
            let schema = Data(words.joined(separator: [0x20]))
            return SHA256.hash(schema).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } | 0x8000_0000
        }

        @Test("A Hello's protocol version is the digest of kernova_v2.proto's schema")
        func helloCarriesTheSchemaDigest() throws {
            let proto = try Data(contentsOf: SourceTree.url("KernovaKit/Sources/KernovaWire/Proto/kernova_v2.proto"))
            var peer = Wire.peer()
            let hello = try #require(
                peer.flush().lazy.compactMap { try? Kernova_V2_SessionMessage(serializedBytes: $0.payload) }.first)
            #expect(hello.hello.protocolVersion == Self.schemaDigest(proto))
        }
    }
}
