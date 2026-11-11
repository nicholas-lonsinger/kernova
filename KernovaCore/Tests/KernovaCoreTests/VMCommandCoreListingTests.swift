import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The narrowed listing and the group verb against a real library: the VMs a
/// query admits are the ones the sidebar lists under the same filter.
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

    /// Five VMs that tell every attribute apart, in library order.
    private func makeMixedLibrary(in harness: WiredCommandCore) {
        makeInstance(in: harness, name: "Zed", guestOS: .macOS, phase: .running(sessionID: UUID()))
        makeInstance(in: harness, name: "Alpha", phase: .running(sessionID: UUID())) {
            $0.applyNetworkMode(.nat)
        }
        makeInstance(in: harness, name: "Mac", guestOS: .macOS, hostState: VMHostState(ephemeralModeEnabled: true))
        makeInstance(
            in: harness, name: "Build", phase: .suspended,
            snapshots: [VMSnapshot(name: "Before", macAddress: nil)]
        ) { $0.applyNetworkMode(.hostOnly) }
        makeInstance(in: harness, name: "Old", guestOS: .macOS) { $0.lastSeenAgentVersion = "0.0.1" }
    }

    private func listed(_ harness: WiredCommandCore, _ query: VMListQuery) throws -> [String] {
        try harness.core.list(harness.core.selection(for: query, verb: .list)).map(\.name)
    }

    /// The refusal resolving `query` throws, `nil` for none.
    private func refusal(_ harness: WiredCommandCore, _ query: VMListQuery) -> CommandError? {
        #expect(throws: CommandError.self) { try harness.core.selection(for: query, verb: .list) }
    }

    private func names(in section: SidebarLayout.Section?) -> [String] {
        guard case .rows(let rows)? = section?.content else { return [] }
        return rows.entries.map(\.name)
    }

    // MARK: - Named networks

    @Test("A network text reads as a mode or a named network, by name or identifier, ignoring case")
    func networkTextsResolve() throws {
        let harness = makeHarness()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .hostOnly)
        makeInstance(in: harness, name: "Member") {
            $0.applyNetworkMode(.hostOnly)
            $0.networkMembership = .network(lab.id)
        }
        makeInstance(in: harness, name: "Shared") { $0.applyNetworkMode(.nat) }
        makeInstance(in: harness, name: "Offline")

        #expect(try listed(harness, VMListQuery(networks: ["lab"])) == ["Member"])
        #expect(try listed(harness, VMListQuery(networks: [lab.id.uuidString.lowercased()])) == ["Member"])
        #expect(try listed(harness, VMListQuery(networks: ["NAT"])) == ["Shared"])
        #expect(
            try listed(harness, VMListQuery(networks: ["Lab", "nat", "None"])) == ["Member", "Shared", "Offline"])

        guard case .itemNotFoundOnHost(let item)? = refusal(harness, VMListQuery(networks: ["Nowhere"])) else {
            Issue.record("expected a not-found refusal")
            return
        }
        #expect(item == "network named \u{201C}Nowhere\u{201D}")
    }

    // MARK: - Tags

    @Test("A tag text reads as a tag's name ignoring case or its identifier, any tag given admitting a VM")
    func tagTextsResolve() throws {
        let harness = makeHarness()
        let work = try harness.library.createTag(named: "Work", color: .blue)
        let lab = try harness.library.createTag(named: "Lab", color: .green)
        makeInstance(in: harness, name: "Both", hostState: VMHostState(tags: [work.id, lab.id]))
        makeInstance(in: harness, name: "Desk", hostState: VMHostState(tags: [work.id]))
        makeInstance(in: harness, name: "Bench", guestOS: .macOS, hostState: VMHostState(tags: [lab.id]))
        makeInstance(in: harness, name: "Plain")

        #expect(try listed(harness, VMListQuery(tags: ["work"])) == ["Both", "Desk"])
        #expect(try listed(harness, VMListQuery(tags: [lab.id.uuidString.lowercased()])) == ["Both", "Bench"])
        #expect(try listed(harness, VMListQuery(tags: ["WORK", "lab"])) == ["Both", "Desk", "Bench"])
        // ANDed with the other flags.
        #expect(
            try listed(harness, VMListQuery(filter: VMLibraryFilter(guestOSes: [.linux]), tags: ["Lab"])) == ["Both"])

        guard case .itemNotFoundOnHost(let item)? = refusal(harness, VMListQuery(tags: ["Home"])) else {
            Issue.record("expected a not-found refusal")
            return
        }
        #expect(item == "tag named \u{201C}Home\u{201D}")
    }

    // MARK: - Folders

    /// The mixed library's entries by name.
    private func ids(_ harness: WiredCommandCore) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: harness.library.entries.map { ($0.name, $0.id) })
    }

    private func folder(_ name: String) -> VMListQuery {
        VMListQuery(groups: [VMGroupReference(.folder, named: name)])
    }

    @Test("A folder lists its members the library holds, in the folder's own order, as its sidebar section does")
    func folderListsItsMembersInItsOwnOrder() throws {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)
        let byName = ids(harness)
        let names = ["Old", "Alpha", "Zed"]
        let client = try harness.library.organization.createFolder(
            named: "Client Project", members: names.compactMap { byName[$0] } + [UUID()])
        let section = harness.library.sidebarLayout.sections.first { $0.id == .folder(client.id) }

        #expect(try listed(harness, folder("client project")) == names)
        #expect(try listed(harness, folder("client project")) == self.names(in: section))
        #expect(try listed(harness, folder(client.id.uuidString)) == names)
        // A stale member is inert, and every other sort orders the members.
        let byNameSort = VMListQuery(groups: folder("Client Project").groups, sort: .name)
        #expect(try listed(harness, byNameSort) == ["Alpha", "Old", "Zed"])
    }

    @Test("A folder the library does not list is refused as not found, a smart group's name included")
    func unknownFolderIsRefused() throws {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)
        try harness.library.organization.createSmartGroup(named: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))

        guard case .itemNotFoundOnHost(let item)? = refusal(harness, folder("Macs")) else {
            Issue.record("expected a not-found refusal")
            return
        }
        #expect(item == "folder named \u{201C}Macs\u{201D}")
    }

    @Test("groups lists the smart groups, then the folders, each folder's members in its own order")
    func groupsListsFoldersAfterSmartGroups() throws {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)
        let byName = ids(harness)
        let macs = try harness.library.organization.createSmartGroup(
            named: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let client = try harness.library.organization.createFolder(
            named: "Client", members: ["Build", "Zed"].compactMap { byName[$0] } + [UUID()])
        let empty = try harness.library.organization.createFolder(named: "Empty")

        let groups = try harness.core.groups()

        #expect(groups.map(\.id) == [macs.id, client.id, empty.id])
        #expect(groups.map(\.kind) == [.smartGroup, .folder, .folder])
        #expect(groups.map { $0.members.map(\.name) } == [["Zed", "Mac", "Old"], ["Build", "Zed"], []])
    }
}
