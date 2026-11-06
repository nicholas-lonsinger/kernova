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
        static let established = PeerEvent.established(host: PeerClaim(role: .host, versionLabel: "host"))
        static let unresponsive = PeerEvent.hostLiveness(.unresponsive(silentFor: .seconds(30)))
        static let responsive = PeerEvent.hostLiveness(.responsive)
        static let closures: [ConnectionClosure] = [
            .closedLocally(WireError(.shuttingDown)), .closedByPeer(WireError(.shuttingDown)), .transportLost,
            .notThisProtocol,
        ]

        @Test("The host's Hello connects")
        func establishedConnects() {
            #expect(HostConnectionState.connecting.after(Self.established) == .connected)
        }

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

        @Test("Events that say nothing about the connection leave every state as it is")
        func otherEventsLeaveIt() {
            let events: [PeerEvent] = [
                .policyReceived(PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true)])),
                .updateAvailable(nil), .itemFeatureUsable(.clipboard, true),
                .diagnostic(.remoteViolation("test")),
            ]
            for state in [HostConnectionState.connecting, .connected, .unresponsive] {
                for event in events {
                    #expect(state.after(event) == state)
                }
            }
        }
    }
}
