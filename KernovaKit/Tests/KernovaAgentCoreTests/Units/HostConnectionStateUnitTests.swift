#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire
import Testing

extension CoreUnits {
    @Suite("HostConnectionState")
    struct HostConnectionStateUnitTests {
        static let unresponsive = PeerEvent.liveness(.unresponsive(silentFor: .seconds(30)))
        static let responsive = PeerEvent.liveness(.responsive)
        static let closures: [ConnectionClosure] = [
            .closedLocally(WireError(.shuttingDown)), .closedByPeer(WireError(.shuttingDown)), .transportLost,
            .notThisProtocol,
        ]

        @Test("An unresponsive verdict leaves a connected peer unresponsive")
        func unresponsive() {
            #expect(HostConnectionState.connected.after(Self.unresponsive) == .unresponsive)
        }

        @Test("A frame after an unresponsive verdict connects again")
        func responsive() {
            #expect(HostConnectionState.unresponsive.after(Self.responsive) == .connected)
        }

        @Test("However the connection ends, the peer is connecting again", arguments: closures)
        func closedReconnects(_ closure: ConnectionClosure) {
            for state in [HostConnectionState.connected, .unresponsive] {
                #expect(state.after(.closed(closure)) == .connecting)
            }
        }
    }
}
