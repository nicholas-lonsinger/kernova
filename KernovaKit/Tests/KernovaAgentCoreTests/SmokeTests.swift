#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire
import Testing

@Suite("Smoke")
struct SmokeTests {
    @Test("A host and a session peer complete the handshake")
    func handshake() {
        let now = CoreInstant(nanoseconds: 1_000_000_000)
        var host = HostEndpoint(
            HostConfiguration(
                claim: PeerClaim(role: .host, versionLabel: "1.0"), sessionToken: Data(repeating: 1, count: 16),
                policy: PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true)]), bundles: []),
            generation: ConnectionGeneration(rawValue: 1), now: now)
        var peer = PeerEndpoint(
            PeerConfiguration(
                claim: PeerClaim(
                    role: .sessionPeer, scope: .user, os: .linux, instanceID: Data(repeating: 2, count: 16)),
                state: PeerSessionState(console: .on, sessionID: "c1"),
                power: .available(PowerOffer(actions: [.shutdown, .restart])), logs: .available(NoParams()),
                update: .absent(.notImplemented, debugDetail: "")),
            generation: ConnectionGeneration(rawValue: 1), now: now)
        for _ in 0..<4 {
            while let transmit = host.pollTransmit(maxBytes: 1 << 20) {
                peer.receive(transmit.chunks.reduce(Data(), +), now: now)
            }
            while let transmit = peer.pollTransmit(maxBytes: 1 << 20) {
                host.receive(transmit.chunks.reduce(Data(), +), now: now)
            }
        }
        #expect(host.state == .established)
        #expect(peer.state == .established)
        var hostEvents: [HostEvent] = []
        while let event = host.pollEvent() { hostEvents.append(event) }
        var peerEffects: [PeerEffect] = []
        while let effect = peer.pollEffect() { peerEffects.append(effect) }
        #expect(peerEffects.contains(.logs(.mode(.forwarding))))
        #expect(hostEvents.contains { if case .helloReceived = $0 { true } else { false } })
    }
}
