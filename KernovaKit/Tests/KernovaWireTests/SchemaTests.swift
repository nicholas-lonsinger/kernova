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
        #expect(PayloadFormat.containerTree.rawValue == 4)
        #expect(StreamKind.logForward.rawValue == 300)
    }
}
