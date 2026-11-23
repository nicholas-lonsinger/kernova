import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCommandModel

@Suite("VMLibraryFilter", .caseScoped)
struct VMLibraryFilterTests {
    /// The one named network these tests' library lists.
    private static let named = UUID()

    /// `choice` as a library listing only ``named`` tells it apart.
    private static func network(_ choice: NetworkModeChoice) -> VMLibraryFilter.Network {
        VMLibraryFilter.Network(choice) { _, id in id == named }
    }

    private func subject(
        guestOS: VMGuestOS = .macOS, state: VMStateBucket = .stopped,
        network: NetworkModeChoice = .nat, guestAgent: VMGuestAgentBucket? = .upToDate,
        isEphemeral: Bool = false, hasSnapshots: Bool = false, tags: Set<UUID> = []
    ) -> VMLibraryFilter.Subject {
        VMLibraryFilter.Subject(
            guestOS: guestOS, state: state, network: Self.network(network), guestAgent: guestAgent,
            isEphemeral: isEphemeral, hasSnapshots: hasSnapshots, tags: tags)
    }

    // MARK: - Coding

    @Test("A missing key decodes as that attribute unconstrained")
    func missingKeysDecodeUnconstrained() throws {
        let decoded = try JSONDecoder().decode(
            VMLibraryFilter.self, from: Data(#"{"states":["running"]}"#.utf8))
        #expect(decoded == VMLibraryFilter(states: [.running]))
    }

    @Test("A network choice codes as one string and reads back")
    func networkChoiceRawValues() throws {
        let cases: [(NetworkModeChoice, String)] = [
            (.none, "none"),
            (.bridged(nil), "bridged"),
            (.bridged("en0"), "bridged:en0"),
            (.nat, "nat:common"),
            (.vmnet(.hostOnly, .isolated), "hostOnly:isolated"),
            (.vmnet(.nat, .network(Self.named)), "nat:\(Self.named.uuidString)"),
        ]
        for (choice, raw) in cases {
            #expect(choice.rawValue == raw)
            #expect(NetworkModeChoice(rawValue: raw) == choice)
            #expect(try JSONDecoder().decode(NetworkModeChoice.self, from: JSONEncoder().encode(choice)) == choice)
        }
        for garbage in ["", "bridged:", "nat", "nat:nowhere", "lan:common"] {
            #expect(NetworkModeChoice(rawValue: garbage) == nil)
        }
    }

    // MARK: - Guest agent buckets

    @Test("The agent bucket is up to date only when every scope's last payload hash is the bundled one")
    func agentBuckets() {
        let bundled = Data(repeating: 1, count: 32)
        let other = Data(repeating: 2, count: 32)
        #expect(VMGuestAgentBucket(lastSeen: [], bundled: bundled) == .neverConnected)
        #expect(VMGuestAgentBucket(lastSeen: [bundled], bundled: bundled) == .upToDate)
        #expect(VMGuestAgentBucket(lastSeen: [bundled, bundled], bundled: bundled) == .upToDate)
        // The hub offers any other payload, newer or older, so a differing hash is out of date — whatever label
        // the agent reports, since two builds can carry one label.
        #expect(VMGuestAgentBucket(lastSeen: [bundled, other], bundled: bundled) == .olderVersion)
        #expect(VMGuestAgentBucket(lastSeen: [other], bundled: bundled) == .olderVersion)
        // A record kept without a hash cannot be the bundled payload.
        #expect(VMGuestAgentBucket(lastSeen: [nil], bundled: bundled) == .olderVersion)
        // A build that bundles nothing for the guest puts a connected agent in no bucket.
        #expect(VMGuestAgentBucket(lastSeen: [other], bundled: nil) == nil)
        #expect(VMGuestAgentBucket(lastSeen: [], bundled: nil) == .neverConnected)
    }

    // MARK: - Spelling

    @Test("A network spelling reads a mode alone as its common network, and every spelling round-trips")
    func networkSpellings() {
        #expect(VMLibraryFilter.Network(spelling: "nat") == Self.network(.vmnet(.nat, .common)))
        #expect(VMLibraryFilter.Network(spelling: "hostOnly") == Self.network(.vmnet(.hostOnly, .common)))
        #expect(VMLibraryFilter.Network(spelling: "nat:common") == Self.network(.vmnet(.nat, .common)))
        #expect(VMLibraryFilter.Network(spelling: "bridged:en0") == Self.network(.bridged("en0")))
        #expect(VMLibraryFilter.Network(spelling: "unlisted") == .unlisted)
        // Case is ignored, but for the interface a bridged network names.
        #expect(VMLibraryFilter.Network(spelling: "Nat") == Self.network(.vmnet(.nat, .common)))
        #expect(VMLibraryFilter.Network(spelling: "HOSTONLY:Isolated") == Self.network(.vmnet(.hostOnly, .isolated)))
        #expect(VMLibraryFilter.Network(spelling: "Bridged:EN0") == Self.network(.bridged("EN0")))
        #expect(VMLibraryFilter.Network(spelling: "Unlisted") == .unlisted)
        #expect(VMLibraryFilter.Network(spelling: "bridged:") == nil)
        for spelling in VMLibraryFilter.Network.spellings {
            #expect(VMLibraryFilter.Network(spelling: spelling) != nil, "\(spelling)")
        }
        #expect(
            VMLibraryFilter.Network.spellings
                == [
                    "nat", "nat:isolated", "hostOnly", "hostOnly:isolated", "bridged", "bridged:automatic",
                    "none", "unlisted",
                ])
    }

    @Test("bridged spells every bridged network, bridged:automatic Automatic, bridged:<interface> that interface")
    func bridgedSpellings() throws {
        #expect(VMLibraryFilter.Network(spelling: "bridged") == .anyBridged)
        #expect(VMLibraryFilter.Network(spelling: "BRIDGED") == .anyBridged)
        #expect(VMLibraryFilter.Network(spelling: "bridged:automatic") == Self.network(.bridged(nil)))
        #expect(VMLibraryFilter.Network(spelling: "Bridged:Automatic") == Self.network(.bridged(nil)))
        #expect(VMLibraryFilter.Network(spelling: "bridged:en0") == Self.network(.bridged("en0")))

        let automatic = subject(network: .bridged(nil))
        let en0 = subject(network: .bridged("en0"))
        let en1 = subject(network: .bridged("en1"))
        let shared = subject(network: .nat)
        func admitted(_ spelling: String) throws -> [Bool] {
            let filter = VMLibraryFilter(networks: [try #require(VMLibraryFilter.Network(spelling: spelling))])
            return [automatic, en0, en1, shared].map(filter.admits)
        }
        #expect(try admitted("bridged") == [true, true, true, false])
        #expect(try admitted("bridged:automatic") == [true, false, false, false])
        #expect(try admitted("bridged:en0") == [false, true, false, false])

        #expect(VMLibraryFilter.Network.anyBridged.choice == nil)
        #expect(VMLibraryFilter.Network(rawValue: VMLibraryFilter.Network.anyBridged.rawValue) == .anyBridged)
        #expect(
            try JSONDecoder().decode(
                VMLibraryFilter.Network.self, from: JSONEncoder().encode(VMLibraryFilter.Network.anyBridged))
                == .anyBridged)
    }

    // MARK: - Sort

    private struct Row {
        let name: String
        var createdAt = Date(timeIntervalSince1970: 0)
        var lastRun = VMLibrarySort.LastRun.unrecorded
    }

    private func sorted(_ rows: [Row], by sort: VMLibrarySort) -> [String] {
        sort.ordered(rows) { VMLibrarySort.Keys(name: $0.name, createdAt: $0.createdAt, lastRun: $0.lastRun) }
            .map(\.name)
    }

    @Test("Each sort has one direction, and rows its key ties keep the order they came in")
    func sortOrders() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let rows = [
            Row(name: "beta", createdAt: base), Row(name: "Alpha 10", createdAt: base + 20),
            Row(name: "Alpha 9", createdAt: base + 10), Row(name: "Twin", createdAt: base),
        ]
        #expect(sorted(rows, by: .manual) == ["beta", "Alpha 10", "Alpha 9", "Twin"])
        #expect(sorted(rows, by: .name) == ["Alpha 9", "Alpha 10", "beta", "Twin"])
        // "beta" and "Twin" tie on creation, so they keep the order they came in.
        #expect(sorted(rows, by: .dateCreated) == ["Alpha 10", "Alpha 9", "beta", "Twin"])
        #expect(VMLibrarySort.allCases.map(\.rawValue) == ["name", "dateCreated", "lastRun", "manual"])
    }
}
