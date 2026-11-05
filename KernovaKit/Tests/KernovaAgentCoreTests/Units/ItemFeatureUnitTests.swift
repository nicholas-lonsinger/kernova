#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentSimulation
import KernovaWire
import Testing

@testable import KernovaAgentCore

@Suite("Item features: what each role advertises")
struct ItemFeatureUnitTests {
    static let offering: [FeatureID] = [.clipboard, .drop, .drag]

    /// A peer endpoint of `role` configured with `items`, and what it advertises of each item feature.
    static func adverts(_ role: PeerRole, _ items: ItemFeatureAvailability) -> [FeatureID: Availability<Data>] {
        var configuration = PeerConfiguration(
            claim: PeerClaim(role: role, scope: role == .systemPeer ? .system : .user), state: PeerSessionState(),
            power: .absent(.notImplemented, debugDetail: ""), logs: .absent(.notImplemented, debugDetail: ""),
            update: .absent(.notImplemented, debugDetail: ""))
        configuration.items = items
        let endpoint = PeerEndpoint(
            configuration, generation: ConnectionGeneration(rawValue: 1), now: CoreInstant(nanoseconds: 1))
        var adverts: [FeatureID: Availability<Data>] = [:]
        for row in endpoint.connection.localAdverts { adverts[row.feature] = row.advert.availability }
        return adverts
    }

    @Test("A system peer advertises CLIPBOARD, DROP and DRAG absent NOT_SERVED_BY_ROLE, whatever it is configured with")
    func systemPeer() {
        let adverts = Self.adverts(.systemPeer, SimItems.served)
        for feature in Self.offering {
            #expect(adverts[feature] == .absent(.notServedByRole, debugDetail: ""), "\(feature)")
        }
        #expect(adverts[.itemTransfer] == .available(Data()))
    }

    @Test("A session peer advertises what it is configured with, and absent NOT_IMPLEMENTED by default")
    func sessionPeer() {
        let served = Self.adverts(.sessionPeer, SimItems.served)
        let unserved = Self.adverts(.sessionPeer, .notImplemented)
        for feature in Self.offering + [.itemTransfer] {
            #expect(served[feature] == .available(Data()), "\(feature)")
            #expect(unserved[feature] == .absent(.notImplemented, debugDetail: ""), "\(feature)")
        }
    }

    @Test("A feature that offers items is absent wherever item transfer is, for its reason")
    func gatedOnItemTransfer() {
        var items = SimItems.served
        items.itemTransfer = .absent(.missingOsComponent, debugDetail: "no sink")
        let adverts = Self.adverts(.sessionPeer, items)
        for feature in Self.offering {
            #expect(adverts[feature] == .absent(.missingOsComponent, debugDetail: "no sink"), "\(feature)")
        }
    }
}

@Suite("Item features: CLIPBOARD's policy params")
struct ClipboardPolicyUnitTests {
    @Test("The paste ceiling and passthrough cross in CLIPBOARD's entry, enabled or not")
    func roundTrips() {
        for enabled in [true, false] {
            for passthrough in [true, false] {
                let value = ClipboardPolicyValue(maxPasteBytes: 1 << 33, passthrough: passthrough)
                let policy = PolicySnapshot([
                    FeaturePolicyValue(feature: .logs, enabled: true), value.policy(enabled: enabled),
                ])
                #expect(policy.isEnabled(.clipboard) == enabled)
                #expect(ClipboardPolicyValue(policy) == value)
            }
        }
    }

    @Test("No CLIPBOARD entry, another version's, or params that do not decode carry no params")
    func absentOrUnreadable() {
        let entry = ClipboardPolicyValue(maxPasteBytes: 7, passthrough: false).policy(enabled: true)
        var otherVersion = entry
        otherVersion.version += 1
        var garbled = entry
        garbled.params = Data([0xFF])
        #expect(ClipboardPolicyValue(PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true)])) == nil)
        #expect(ClipboardPolicyValue(PolicySnapshot([otherVersion])) == nil)
        #expect(ClipboardPolicyValue(PolicySnapshot([garbled])) == nil)
    }
}
