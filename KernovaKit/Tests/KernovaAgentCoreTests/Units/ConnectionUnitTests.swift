#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import KernovaAgentCore
import KernovaWire
import SwiftProtobuf
import Testing

extension CoreUnits {
    @Suite("Connection: transmit order, credit, misuse, coalescing, diagnostics")
    struct ConnectionUnitTests {

        // MARK: Coalescing

        @Test("Unsent snapshots coalesce in the transmit queue, the newest replacing the older")
        func coalescedTransmit() {
            var peer = Wire.peer()
            peer.establish()
            for name in ["a", "b", "c"] {
                peer.connection.setPeerState(PeerSessionState(console: .on, sessionID: "c1", userName: name))
            }
            var adverts = Unit.peerAdverts()
            adverts[0].1 = LocalAdvert(version: 1, availability: .absent(.notOnConsole, debugDetail: ""))
            peer.connection.setLocalAdverts(adverts)
            peer.connection.setLocalAdverts(Array(Unit.peerAdverts().reversed()))
            peer.connection.setLocalAdverts(adverts)
            let frames = peer.flush()
            #expect(frames.shape == ["0:data+msg", "0:data+msg"])
            let messages = frames.compactMap { try? Kernova_V2_SessionMessage(wire: $0.payload) }
            #expect(messages.first?.peerState.userName == "c")
            #expect(messages.last?.capabilities.features.first?.absent.reason == .notOnConsole)

            var host = Wire.host()
            host.establish()
            host.connection.setPolicy(PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: false)]))
            host.connection.setPolicy(
                PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true, params: Data([1]))]))
            let policies = host.flush().compactMap { try? Kernova_V2_SessionMessage(wire: $0.payload) }
            #expect(policies.count == 1)
            #expect(policies.first?.policy.features.first?.params == Data([1]))
        }
    }
}
