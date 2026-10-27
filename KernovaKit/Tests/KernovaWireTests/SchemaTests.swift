#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf
import Testing

@Suite("Generated schema")
struct SchemaTests {
    @Test("The vocabulary typealiases name the generated enums, with the proto's numbers")
    func vocabulary() {
        #expect(ErrorCode.protocolError.rawValue == 1)
        #expect(ErrorCode.frameTooLarge.rawValue == 2)
        #expect(ErrorCode.superseded.rawValue == 10)
        #expect(ErrorCode.updateInProgress.rawValue == 126)
        #expect(FeatureID.logs.rawValue == 3)
        #expect(AbsenceReason.noAgent.rawValue == 103)
        #expect(PowerAction.restart.rawValue == 2)
        #expect(PayloadFormat.paxTree.rawValue == 2)
        #expect(StreamKind.logForward.rawValue == 300)
    }

    @Test("A Hello encodes in field order and decodes back")
    func helloRoundTrip() throws {
        var identity = Kernova_V2_PeerIdentity()
        identity.role = .sessionPeer
        identity.os = .linux
        identity.instanceID = Data(repeating: 7, count: 16)
        var advert = Kernova_V2_FeatureAdvert()
        advert.feature = .power
        advert.version = 1
        advert.params = Data([0x08, 0x01])
        var hello = Kernova_V2_Hello()
        hello.protocolVersion = 1
        hello.identity = identity
        hello.features = [advert]
        var message = Kernova_V2_SessionMessage()
        message.hello = hello

        let bytes: Data = try message.serializedBytes()
        #expect(try bytes == message.serializedBytes())
        #expect(try Kernova_V2_SessionMessage(serializedBytes: bytes) == message)
        #expect(bytes.first == 0x0A)  // field 1 (hello), length-delimited
    }
}
