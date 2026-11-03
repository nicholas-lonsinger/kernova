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
