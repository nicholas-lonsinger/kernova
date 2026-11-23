import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The narrowed listing against a real library: how a query's texts resolve.
@Suite("VMCommandCore listing", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreListingTests {
    private let preferences = makeTestPreferences()

    private func makeHarness() -> WiredCommandCore {
        WiredCommandCore(preferences: preferences)
    }

    @discardableResult
    private func makeInstance(
        in harness: WiredCommandCore, name: String, guestOS: VMGuestOS = .linux,
        phase: VMLifecyclePhase = .stopped, snapshots: [VMSnapshot] = [],
        hostState: VMHostState = VMHostState(), mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots, library: harness.library,
            preferences: preferences, hostState: hostState, mutate: mutate)
    }

    private func listed(_ harness: WiredCommandCore, _ query: VMListQuery) throws -> [String] {
        try harness.core.list(harness.core.selection(for: query, verb: .list)).map(\.name)
    }

    /// The refusal resolving `query` throws, `nil` for none.
    private func refusal(_ harness: WiredCommandCore, _ query: VMListQuery) -> CommandError? {
        #expect(throws: CommandError.self) { try harness.core.selection(for: query, verb: .list) }
    }

    // MARK: - Named networks

    @Test("A text naming both a mode and a named network is refused with the identifier that picks the network")
    func ambiguousNetworkTextIsRefused() throws {
        let harness = makeHarness()
        let shadow = try harness.core.createNetwork(name: "NAT", kind: .hostOnly)
        makeInstance(in: harness, name: "Member") {
            $0.applyNetworkMode(.hostOnly)
            $0.networkMembership = .network(shadow.id)
        }

        guard case .invalidArgument(let message)? = refusal(harness, VMListQuery(networks: ["nat"])) else {
            Issue.record("expected an invalid-argument refusal")
            return
        }
        #expect(message.contains(shadow.id.uuidString))
        #expect(try listed(harness, VMListQuery(networks: [shadow.id.uuidString])) == ["Member"])
    }
}
