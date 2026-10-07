import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

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
        network: NetworkModeChoice = .shared, guestAgent: VMGuestAgentBucket? = .upToDate,
        isEphemeral: Bool = false, hasSnapshots: Bool = false, tags: Set<UUID> = []
    ) -> VMLibraryFilter.Subject {
        VMLibraryFilter.Subject(
            guestOS: guestOS, state: state, network: Self.network(network), guestAgent: guestAgent,
            isEphemeral: isEphemeral, hasSnapshots: hasSnapshots, tags: tags)
    }

    // MARK: - Evaluation

    @Test("The empty filter admits everything and is inactive")
    func emptyAdmitsAll() {
        let filter = VMLibraryFilter()
        #expect(!filter.isActive)
        #expect(filter.admits(subject()))
        #expect(filter.admits(subject(guestOS: .linux, state: .preparing, network: .none, guestAgent: nil)))
    }

    @Test("Guest OS admits only the OSes in its set")
    func guestOS() {
        let filter = VMLibraryFilter(guestOSes: [.linux])
        #expect(filter.isActive)
        #expect(filter.admits(subject(guestOS: .linux)))
        #expect(!filter.admits(subject(guestOS: .macOS)))
    }

    @Test("State admits only the buckets in its set")
    func state() {
        let filter = VMLibraryFilter(states: [.running])
        #expect(filter.admits(subject(state: .running)))
        #expect(!filter.admits(subject(state: .suspended)))
        #expect(!filter.admits(subject(state: .heldByAnotherCopy)))
    }

    @Test("Network admits only the choices in its set, membership included")
    func network() {
        let filter = VMLibraryFilter(networks: [
            Self.network(.vmnet(.shared, .network(Self.named))), Self.network(.none),
        ])
        #expect(filter.admits(subject(network: .vmnet(.shared, .network(Self.named)))))
        #expect(filter.admits(subject(network: .none)))
        #expect(!filter.admits(subject(network: .shared)))
        #expect(!filter.admits(subject(network: .vmnet(.hostOnly, .network(Self.named)))))
    }

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
            guestOSes: [.macOS], states: [.running], networks: [Self.network(.shared)], guestAgents: [.upToDate],
            ephemeralOnly: true, withSnapshotsOnly: true, tags: [work])
        let passing = subject(
            state: .running, network: .shared, guestAgent: .upToDate, isEphemeral: true, hasSnapshots: true,
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

    @Test("Admitting a subject drops only the attributes it fails")
    func admittingRelaxesFailedAttributes() {
        let work = UUID()
        let filter = VMLibraryFilter(guestOSes: [.macOS], states: [.stopped], ephemeralOnly: true, tags: [work])
        let running = subject(state: .running, isEphemeral: true)

        let relaxed = filter.admitting(running)

        #expect(relaxed == VMLibraryFilter(guestOSes: [.macOS], ephemeralOnly: true))
        #expect(relaxed.admits(running))
        #expect(filter.admitting(subject(isEphemeral: true, tags: [work])) == filter)
    }

    // MARK: - Coding

    @Test("A filter round-trips through JSON with every attribute set")
    func codableRoundTrip() throws {
        let filter = VMLibraryFilter(
            guestOSes: [.macOS, .linux], states: [.suspended],
            networks: Set(
                [
                    .shared, .vmnet(.hostOnly, .isolated), .vmnet(.shared, .network(Self.named)),
                    .bridged(nil), .bridged("en0"), .none,
                ].map(Self.network)
            ).union([.unlisted]),
            guestAgents: [.neverConnected], ephemeralOnly: true, withSnapshotsOnly: true, tags: [UUID(), UUID()])

        let data = try JSONEncoder().encode(filter)
        #expect(try JSONDecoder().decode(VMLibraryFilter.self, from: data) == filter)
    }

    @Test("Equal filters encode to equal bytes under sorted keys, whatever their sets' order")
    func encodingIsStable() throws {
        let encoder = JSONEncoder()
        // Key order is the encoder's to choose; only the values are the
        // filter's, so byte stability is claimed under sorted keys.
        encoder.outputFormatting = .sortedKeys
        let tags = (0..<4).map { _ in UUID() }
        let forward = VMLibraryFilter(
            guestOSes: [.macOS, .linux], states: [.running, .suspended, .stopped],
            guestAgents: [.upToDate, .olderVersion, .neverConnected], tags: Set(tags))
        var backward = VMLibraryFilter()
        for tag in tags.reversed() { backward.tags.insert(tag) }
        for os in VMGuestOS.allCases.reversed() { backward.guestOSes.insert(os) }
        for state in [VMStateBucket.stopped, .suspended, .running] { backward.states.insert(state) }
        for agent in VMGuestAgentBucket.allCases.reversed() { backward.guestAgents.insert(agent) }
        #expect(forward == backward)

        #expect(try encoder.encode(forward) == encoder.encode(backward))
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
            (.shared, "shared:common"),
            (.vmnet(.hostOnly, .isolated), "hostOnly:isolated"),
            (.vmnet(.shared, .network(Self.named)), "shared:\(Self.named.uuidString)"),
        ]
        for (choice, raw) in cases {
            #expect(choice.rawValue == raw)
            #expect(NetworkModeChoice(rawValue: raw) == choice)
            #expect(try JSONDecoder().decode(NetworkModeChoice.self, from: JSONEncoder().encode(choice)) == choice)
        }
        for garbage in ["", "bridged:", "shared", "shared:nowhere", "lan:common"] {
            #expect(NetworkModeChoice(rawValue: garbage) == nil)
        }
    }

    // MARK: - Network key

    @Test("Every named network the library does not list is one network to a filter")
    func unlistedNetworksAreOne() {
        let elsewhere = VMLibraryFilter.Network(.vmnet(.shared, .network(UUID()))) { _, _ in false }
        let elsewhereToo = VMLibraryFilter.Network(.vmnet(.hostOnly, .network(UUID()))) { _, _ in false }
        #expect(elsewhere == .unlisted)
        #expect(elsewhereToo == .unlisted)
        #expect(elsewhere.choice == nil)

        // A filter set to it admits a VM on any network the library does not
        // list — one imported later included.
        let filter = VMLibraryFilter(networks: [elsewhere])
        #expect(filter.admits(subject(network: .vmnet(.hostOnly, .network(UUID())))))
        #expect(!filter.admits(subject(network: .vmnet(.shared, .network(Self.named)))))
    }

    @Test("A listed named network, and every other choice, is itself")
    func listedNetworksStayThemselves() {
        let listed = Self.network(.vmnet(.shared, .network(Self.named)))
        #expect(listed.choice == .vmnet(.shared, .network(Self.named)))
        // The kind is part of what is listed: the same identifier under the
        // other kind is a network the library does not list.
        let otherKind = VMLibraryFilter.Network(.vmnet(.hostOnly, .network(Self.named))) { kind, id in
            kind == .shared && id == Self.named
        }
        #expect(otherKind == .unlisted)
        for choice: NetworkModeChoice in [.none, .shared, .hostOnly, .bridged(nil), .bridged("en0")] {
            #expect(VMLibraryFilter.Network(choice) { _, _ in false }.choice == choice)
        }
    }

    @Test("A network key codes as one string and reads back")
    func networkKeyRawValues() throws {
        #expect(VMLibraryFilter.Network.unlisted.rawValue == "unlisted")
        #expect(VMLibraryFilter.Network(rawValue: "unlisted") == .unlisted)
        let shared = Self.network(.shared)
        #expect(shared.rawValue == "shared:common")
        #expect(VMLibraryFilter.Network(rawValue: "shared:common") == shared)
        #expect(VMLibraryFilter.Network(rawValue: "nowhere") == nil)
        #expect(
            try JSONDecoder().decode(
                VMLibraryFilter.Network.self, from: JSONEncoder().encode(VMLibraryFilter.Network.unlisted))
                == .unlisted)
    }

    // MARK: - Guest agent buckets

    @Test("The agent bucket compares the last-seen version against the bundled one")
    func agentBuckets() {
        #expect(VMGuestAgentBucket(lastSeenVersion: nil, bundledVersion: "1.2.0") == .neverConnected)
        #expect(VMGuestAgentBucket(lastSeenVersion: "1.1.9", bundledVersion: "1.2.0") == .olderVersion)
        #expect(VMGuestAgentBucket(lastSeenVersion: "1.2.0", bundledVersion: "1.2.0") == .upToDate)
        #expect(VMGuestAgentBucket(lastSeenVersion: "1.10.0", bundledVersion: "1.2.0") == .upToDate)
        // A build that does not know its own version calls no agent old.
        #expect(VMGuestAgentBucket(lastSeenVersion: "0.1", bundledVersion: nil) == .upToDate)
    }

    // MARK: - Spelling

    @Test("A network spelling reads a mode alone as its common network, and every spelling round-trips")
    func networkSpellings() {
        #expect(VMLibraryFilter.Network(spelling: "shared") == Self.network(.vmnet(.shared, .common)))
        #expect(VMLibraryFilter.Network(spelling: "hostOnly") == Self.network(.vmnet(.hostOnly, .common)))
        #expect(VMLibraryFilter.Network(spelling: "shared:common") == Self.network(.vmnet(.shared, .common)))
        #expect(VMLibraryFilter.Network(spelling: "bridged:en0") == Self.network(.bridged("en0")))
        #expect(VMLibraryFilter.Network(spelling: "unlisted") == .unlisted)
        // Case is ignored, but for the interface a bridged network names.
        #expect(VMLibraryFilter.Network(spelling: "Shared") == Self.network(.vmnet(.shared, .common)))
        #expect(VMLibraryFilter.Network(spelling: "HOSTONLY:Isolated") == Self.network(.vmnet(.hostOnly, .isolated)))
        #expect(VMLibraryFilter.Network(spelling: "Bridged:EN0") == Self.network(.bridged("EN0")))
        #expect(VMLibraryFilter.Network(spelling: "Unlisted") == .unlisted)
        #expect(VMLibraryFilter.Network(spelling: "bridged:") == nil)
        for spelling in VMLibraryFilter.Network.spellings {
            #expect(VMLibraryFilter.Network(spelling: spelling) != nil, "\(spelling)")
        }
        #expect(
            VMLibraryFilter.Network.spellings
                == ["shared", "shared:isolated", "hostOnly", "hostOnly:isolated", "bridged", "none", "unlisted"])
    }

    @Test("A network spelling never names a named network, which only the library resolves")
    func networkSpellingRefusesNames() {
        #expect(VMLibraryFilter.Network(spelling: "Lab") == nil)
        #expect(VMLibraryFilter.Network(spelling: "Shared Lab") == nil)
        #expect(VMLibraryFilter.Network(spelling: "shared:\(Self.named.uuidString)") == nil)
        #expect(VMLibraryFilter.Network(spelling: Self.named.uuidString) == nil)
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

    @Test("A named network the library stops listing, still held by a filter, admits no VM")
    func heldUnlistedNetworkAdmitsNothing() {
        let id = UUID()
        let held = VMLibraryFilter.Network(.vmnet(.shared, .network(id))) { _, _ in true }
        let filter = VMLibraryFilter(networks: [held])
        // A VM still naming it reads as on a network the library does not
        // list, which is not the held value; every other VM is on its own.
        let stillNaming = VMLibraryFilter.Network(.vmnet(.shared, .network(id))) { _, _ in false }
        #expect(stillNaming == .unlisted)
        for network in [stillNaming, VMLibraryFilter.Network(.vmnet(.shared, .isolated)) { _, _ in true }] {
            let subject = VMLibraryFilter.Subject(
                guestOS: .linux, state: .stopped, network: network, guestAgent: nil, isEphemeral: false,
                hasSnapshots: false)
            #expect(!filter.admits(subject))
        }
    }
}
