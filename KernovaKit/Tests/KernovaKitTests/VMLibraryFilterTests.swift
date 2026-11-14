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

    // MARK: - Evaluation

    @Test("Guest Agent admits only macOS guests in its buckets")
    func guestAgent() {
        let filter = VMLibraryFilter(guestAgents: [.olderVersion, .neverConnected])
        #expect(filter.admits(subject(guestAgent: .olderVersion)))
        #expect(!filter.admits(subject(guestAgent: .upToDate)))
        // A Linux guest has no agent bucket, so no agent filter admits it.
        #expect(!filter.admits(subject(guestOS: .linux, guestAgent: nil)))
    }

    @Test("Each flag admits only VMs that have it")
    func flags() {
        #expect(VMLibraryFilter(ephemeralOnly: true).admits(subject(isEphemeral: true)))
        #expect(!VMLibraryFilter(ephemeralOnly: true).admits(subject(isEphemeral: false)))
        #expect(VMLibraryFilter(withSnapshotsOnly: true).admits(subject(hasSnapshots: true)))
        #expect(!VMLibraryFilter(withSnapshotsOnly: true).admits(subject(hasSnapshots: false)))
    }

    @Test("Tags admit a VM carrying any tag in the set")
    func tags() {
        let work = UUID()
        let lab = UUID()
        let filter = VMLibraryFilter(tags: [work, lab])
        #expect(filter.isActive)
        #expect(filter.admits(subject(tags: [work])))
        #expect(filter.admits(subject(tags: [lab, UUID()])))
        #expect(!filter.admits(subject(tags: [UUID()])))
        #expect(!filter.admits(subject()))
    }

    @Test("Attributes are ANDed")
    func attributesAnd() {
        let work = UUID()
        let filter = VMLibraryFilter(
            guestOSes: [.macOS], states: [.running], networks: [Self.network(.nat)], guestAgents: [.upToDate],
            ephemeralOnly: true, withSnapshotsOnly: true, tags: [work])
        let passing = subject(
            state: .running, network: .nat, guestAgent: .upToDate, isEphemeral: true, hasSnapshots: true,
            tags: [work])
        #expect(filter.admits(passing))
        var failsOne = [passing, passing, passing, passing, passing, passing, passing]
        failsOne[0].guestOS = .linux
        failsOne[1].state = .stopped
        failsOne[2].network = Self.network(.none)
        failsOne[3].guestAgent = .olderVersion
        failsOne[4].isEphemeral = false
        failsOne[5].hasSnapshots = false
        failsOne[6].tags = []
        for failing in failsOne { #expect(!filter.admits(failing)) }
    }

    // MARK: - Coding

    @Test("A filter round-trips through JSON with every attribute set")
    func codableRoundTrip() throws {
        let filter = VMLibraryFilter(
            guestOSes: [.macOS, .linux], states: [.suspended],
            networks: Set(
                [
                    .nat, .vmnet(.hostOnly, .isolated), .vmnet(.nat, .network(Self.named)),
                    .bridged(nil), .bridged("en0"), .none,
                ].map(Self.network)
            ).union([.unlisted]),
            guestAgents: [.neverConnected], ephemeralOnly: true, withSnapshotsOnly: true, tags: [UUID(), UUID()])

        let data = try JSONEncoder().encode(filter)
        #expect(try JSONDecoder().decode(VMLibraryFilter.self, from: data) == filter)
    }

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

    // MARK: - Network key

    @Test("Every named network the library does not list is one network to a filter")
    func unlistedNetworksAreOne() {
        let elsewhere = VMLibraryFilter.Network(.vmnet(.nat, .network(UUID()))) { _, _ in false }
        let elsewhereToo = VMLibraryFilter.Network(.vmnet(.hostOnly, .network(UUID()))) { _, _ in false }
        #expect(elsewhere == .unlisted)
        #expect(elsewhereToo == .unlisted)
        #expect(elsewhere.choice == nil)

        // A filter set to it admits a VM on any network the library does not
        // list — one imported later included.
        let filter = VMLibraryFilter(networks: [elsewhere])
        #expect(filter.admits(subject(network: .vmnet(.hostOnly, .network(UUID())))))
        #expect(!filter.admits(subject(network: .vmnet(.nat, .network(Self.named)))))
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

    @Test("Last run lists live VMs first, then most recent first, then none recorded, each tie A→Z")
    func lastRunOrder() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let rows = [
            Row(name: "unrecorded b"), Row(name: "older", lastRun: .ended(base)),
            Row(name: "Live b", lastRun: .live), Row(name: "recent", lastRun: .ended(base + 60)),
            Row(name: "Unrecorded a"), Row(name: "twin b", lastRun: .ended(base + 30)),
            Row(name: "live a", lastRun: .live), Row(name: "Twin a", lastRun: .ended(base + 30)),
        ]
        #expect(
            sorted(rows, by: .lastRun)
                == ["live a", "Live b", "recent", "Twin a", "twin b", "older", "Unrecorded a", "unrecorded b"])
    }
}
