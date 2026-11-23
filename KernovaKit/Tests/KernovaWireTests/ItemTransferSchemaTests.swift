#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf
import Testing

@Suite("Item transfer schema")
struct ItemTransferSchemaTests {
    @Test("The item-set, outcome and record messages carry the proto's numbers")
    func itemSetAndRecordFields() throws {
        var setHeader = Kernova_V2_ItemSetHeader()
        setHeader.concealed = true
        setHeader.count = 1
        setHeader.token = Data([0xAA])
        #expect(try setHeader.serializedBytes() == [0x08, 1, 0x18, 1, 0x22, 1, 0xAA])
        var answering = Kernova_V2_ItemSetHeader()
        answering.request = Data([0xBB])
        #expect(try answering.serializedBytes() == [0x42, 1, 0xBB])

        var type = TypeDescriptor()
        type.mime = "a"
        type.native = ["b"]
        #expect(try type.serializedBytes() == [0x0A, 1, 0x61, 0x12, 1, 0x62])

        var representation = Kernova_V2_Representation()
        representation.type = TypeDescriptor()
        representation.storage = .file
        representation.promised = true
        representation.sizeEstimate = 1
        representation.name = Data([0x61])
        #expect(try representation.serializedBytes() == [0x0A, 0, 0x10, 2, 0x18, 1, 0x20, 1, 0x2A, 1, 0x61])

        var item = Kernova_V2_Item()
        item.representations = [Kernova_V2_Representation()]
        #expect(try item.serializedBytes() == [0x0A, 0])

        var outcome = Kernova_V2_PullOutcome()
        outcome.kind = .failed
        outcome.error = Kernova_V2_Error()
        #expect(try outcome.serializedBytes() == [0x08, 2, 0x12, 0])

        var time = Kernova_V2_Timespec()
        time.seconds = 1
        time.nanoseconds = 1
        #expect(try time.serializedBytes() == [0x08, 1, 0x10, 1])

        var xattr = Kernova_V2_Xattr()
        xattr.name = Data([0x61])
        xattr.value = Data([0x62])
        #expect(try xattr.serializedBytes() == [0x0A, 1, 0x61, 0x12, 1, 0x62])

        var plain = Kernova_V2_PlainStorage()
        plain.size = 1
        #expect(try plain.serializedBytes() == [0x08, 1])
        var lz4 = Kernova_V2_Lz4Storage()
        lz4.size = 1
        #expect(try lz4.serializedBytes() == [0x08, 1])

        var end = Kernova_V2_EndRecord()
        end.entries = 1
        end.bytes = 1
        #expect(try end.serializedBytes() == [0x08, 1, 0x10, 1])
    }
}
