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
        isEphemeral: Bool = false, hasSnapshots: Bool = false
    ) -> VMLibraryFilter.Subject {
        VMLibraryFilter.Subject(
            guestOS: guestOS, state: state, network: Self.network(network), guestAgent: guestAgent,
            isEphemeral: isEphemeral, hasSnapshots: hasSnapshots)
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

    @Test("Attributes are ANDed")
    func attributesAnd() {
        let filter = VMLibraryFilter(
            guestOSes: [.macOS], states: [.running], networks: [Self.network(.shared)], guestAgents: [.upToDate],
            ephemeralOnly: true, withSnapshotsOnly: true)
        let passing = subject(
            state: .running, network: .shared, guestAgent: .upToDate, isEphemeral: true, hasSnapshots: true)
        #expect(filter.admits(passing))
        var failsOne = [passing, passing, passing, passing, passing, passing]
        failsOne[0].guestOS = .linux
        failsOne[1].state = .stopped
        failsOne[2].network = Self.network(.none)
        failsOne[3].guestAgent = .olderVersion
        failsOne[4].isEphemeral = false
        failsOne[5].hasSnapshots = false
        for failing in failsOne { #expect(!filter.admits(failing)) }
    }

    @Test("Admitting a subject drops only the attributes it fails")
    func admittingRelaxesFailedAttributes() {
        let filter = VMLibraryFilter(guestOSes: [.macOS], states: [.stopped], ephemeralOnly: true)
        let running = subject(state: .running, isEphemeral: true)

        let relaxed = filter.admitting(running)

        #expect(relaxed == VMLibraryFilter(guestOSes: [.macOS], ephemeralOnly: true))
        #expect(relaxed.admits(running))
        #expect(filter.admitting(subject(isEphemeral: true)) == filter)
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
            guestAgents: [.neverConnected], ephemeralOnly: true, withSnapshotsOnly: true)

        let data = try JSONEncoder().encode(filter)
        #expect(try JSONDecoder().decode(VMLibraryFilter.self, from: data) == filter)
        // Equal filters encode to equal bytes, whatever their sets' order.
        #expect(try JSONEncoder().encode(filter) == data)
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
}
