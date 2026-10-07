import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The narrowed listing and the group verb against a real library: the VMs a
/// query admits are the ones the sidebar lists under the same filter.
@Suite("VMCommandCore listing", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreListingTests {
    private let preferences = makeTestPreferences()

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
    }

    private func makeHarness() -> Harness {
        let storage = MockVMStorageService()
        let fileSystem = MockFileSystem()
        let lifecycle = makeTestLifecycle(
            virtualization: MockVirtualizationService(), fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: MockVMBundleMachineFiles(), lifecycle: lifecycle,
            fileSystem: fileSystem, preferences: preferences)
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem,
            preferences: preferences)
        return Harness(core: core, library: library)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String, guestOS: VMGuestOS = .linux,
        phase: VMLifecyclePhase = .stopped, snapshots: [VMSnapshot] = [],
        hostState: VMHostState = VMHostState(), mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots, library: harness.library,
            preferences: preferences, hostState: hostState, mutate: mutate)
    }

    /// Five VMs that tell every attribute apart, in library order.
    private func makeMixedLibrary(in harness: Harness) {
        makeInstance(in: harness, name: "Zed", guestOS: .macOS, phase: .running(sessionID: UUID()))
        makeInstance(in: harness, name: "Alpha", phase: .running(sessionID: UUID())) {
            $0.applyNetworkMode(.shared)
        }
        makeInstance(in: harness, name: "Mac", guestOS: .macOS, hostState: VMHostState(ephemeralModeEnabled: true))
        makeInstance(
            in: harness, name: "Build", phase: .suspended,
            snapshots: [VMSnapshot(name: "Before", macAddress: nil)]
        ) { $0.applyNetworkMode(.hostOnly) }
        makeInstance(in: harness, name: "Old", guestOS: .macOS) { $0.lastSeenAgentVersion = "0.0.1" }
    }

    private func listed(_ harness: Harness, _ query: VMListQuery) throws -> [String] {
        try harness.core.list(harness.core.selection(for: query, verb: .list)).map(\.name)
    }

    /// The refusal resolving `query` throws, `nil` for none.
    private func refusal(_ harness: Harness, _ query: VMListQuery) -> CommandError? {
        #expect(throws: CommandError.self) { try harness.core.selection(for: query, verb: .list) }
    }

    private func names(in section: SidebarLayout.Section?) -> [String] {
        guard case .rows(let rows)? = section?.content else { return [] }
        return rows.entries.map(\.name)
    }

    // MARK: - Order

    @Test("An unconstrained query lists every VM in library order, as the whole-library listing does")
    func defaultQueryIsTheManualOrder() throws {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)

        #expect(try listed(harness, VMListQuery()) == ["Zed", "Alpha", "Mac", "Build", "Old"])
        #expect(try listed(harness, VMListQuery()) == harness.core.list(.all).map(\.name))
    }

    @Test("--sort orders by name A→Z and by creation newest first, ties keeping library order")
    func sortOrdersTheListing() throws {
        let harness = makeHarness()
        let base = Date(timeIntervalSince1970: 1_000_000)
        makeInstance(in: harness, name: "beta") { $0.createdAt = base }
        makeInstance(in: harness, name: "Alpha 10") { $0.createdAt = base.addingTimeInterval(20) }
        makeInstance(in: harness, name: "Alpha 9") { $0.createdAt = base.addingTimeInterval(10) }
        makeInstance(in: harness, name: "Twin") { $0.createdAt = base }

        #expect(try listed(harness, VMListQuery(sort: .name)) == ["Alpha 9", "Alpha 10", "beta", "Twin"])
        #expect(
            try listed(harness, VMListQuery(sort: .dateCreated)) == ["Alpha 10", "Alpha 9", "beta", "Twin"])
        #expect(try listed(harness, VMListQuery(sort: .manual)) == ["beta", "Alpha 10", "Alpha 9", "Twin"])
    }

    // MARK: - Filter

    @Test("Every filter lists exactly what the sidebar's library section lists under it")
    func filterMatchesTheSidebar() throws {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)
        let filters: [VMLibraryFilter] = [
            VMLibraryFilter(guestOSes: [.linux]),
            VMLibraryFilter(states: [.running, .suspended]),
            VMLibraryFilter(guestOSes: [.macOS], states: [.stopped]),
            VMLibraryFilter(networks: [.init(spelling: "shared")!, .init(spelling: "none")!]),
            VMLibraryFilter(guestAgents: [.olderVersion]),
            VMLibraryFilter(guestAgents: [.neverConnected, .olderVersion]),
            VMLibraryFilter(ephemeralOnly: true),
            VMLibraryFilter(withSnapshotsOnly: true),
        ]
        for filter in filters {
            harness.library.sidebarOptions.filter = filter
            let sidebar = names(in: harness.library.sidebarLayout.sections.last)
            #expect(try listed(harness, VMListQuery(filter: filter)) == sidebar, "\(filter)")
        }
        // The fixtures tell the filters apart, so the comparison is not vacuous.
        #expect(try listed(harness, VMListQuery(filter: filters[0])) == ["Alpha", "Build"])
        #expect(try listed(harness, VMListQuery(filter: filters[2])) == ["Mac", "Old"])
        #expect(try listed(harness, VMListQuery(filter: filters[4])) == ["Old"])
        #expect(try listed(harness, VMListQuery(filter: filters[6])) == ["Mac"])
        #expect(try listed(harness, VMListQuery(filter: filters[7])) == ["Build"])
    }

    @Test("An arrival is listed exactly where the sidebar's filter admits it")
    func arrivalsFollowTheFilter() async throws {
        let harness = makeHarness()
        makeInstance(in: harness, name: "Running", phase: .running(sessionID: UUID()))
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(named: "Arriving", guestOS: .linux, gate: gate)

        #expect(try listed(harness, VMListQuery()) == ["Running", "Arriving"])
        #expect(try listed(harness, VMListQuery(filter: VMLibraryFilter(states: [.preparing]))) == ["Arriving"])
        #expect(try listed(harness, VMListQuery(filter: VMLibraryFilter(states: [.running]))) == ["Running"])
        #expect(try listed(harness, VMListQuery(filter: VMLibraryFilter(guestOSes: [.macOS]))).isEmpty)
        for filter in [VMLibraryFilter(states: [.preparing]), VMLibraryFilter(guestOSes: [.linux])] {
            harness.library.sidebarOptions.filter = filter
            #expect(
                try listed(harness, VMListQuery(filter: filter))
                    == names(in: harness.library.sidebarLayout.sections.last))
        }

        gate.release()
        _ = await arrival.settle()
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
        makeInstance(in: harness, name: "Shared") { $0.applyNetworkMode(.shared) }
        makeInstance(in: harness, name: "Offline")

        #expect(try listed(harness, VMListQuery(networks: ["lab"])) == ["Member"])
        #expect(try listed(harness, VMListQuery(networks: [lab.id.uuidString.lowercased()])) == ["Member"])
        #expect(try listed(harness, VMListQuery(networks: ["SHARED"])) == ["Shared"])
        #expect(
            try listed(harness, VMListQuery(networks: ["Lab", "shared", "None"])) == ["Member", "Shared", "Offline"])

        guard case .itemNotFoundOnHost(let item)? = refusal(harness, VMListQuery(networks: ["Nowhere"])) else {
            Issue.record("expected a not-found refusal")
            return
        }
        #expect(item == "network named \u{201C}Nowhere\u{201D}")
    }

    @Test("A text naming both a mode and a named network is refused with the identifier that picks the network")
    func ambiguousNetworkTextIsRefused() throws {
        let harness = makeHarness()
        let shadow = try harness.core.createNetwork(name: "Shared", kind: .hostOnly)
        makeInstance(in: harness, name: "Member") {
            $0.applyNetworkMode(.hostOnly)
            $0.networkMembership = .network(shadow.id)
        }

        guard case .invalidArgument(let message)? = refusal(harness, VMListQuery(networks: ["shared"])) else {
            Issue.record("expected an invalid-argument refusal")
            return
        }
        #expect(message.contains(shadow.id.uuidString))
        #expect(try listed(harness, VMListQuery(networks: [shadow.id.uuidString])) == ["Member"])
    }

    @Test("A VM on a network the library does not list passes the unlisted network")
    func unlistedNetworkMatches() throws {
        let harness = makeHarness()
        makeInstance(in: harness, name: "Stray") {
            $0.applyNetworkMode(.shared)
            $0.networkMembership = .network(UUID())
        }
        makeInstance(in: harness, name: "Common") { $0.applyNetworkMode(.shared) }

        #expect(try listed(harness, VMListQuery(filter: VMLibraryFilter(networks: [.unlisted]))) == ["Stray"])
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

    @Test("A tag filter lists exactly what the sidebar's library section lists under it")
    func tagFilterMatchesTheSidebar() throws {
        let harness = makeHarness()
        let work = try harness.library.createTag(named: "Work", color: .blue)
        let lab = try harness.library.createTag(named: "Lab", color: .green)
        makeInstance(in: harness, name: "Both", hostState: VMHostState(tags: [work.id, lab.id]))
        makeInstance(in: harness, name: "Desk", guestOS: .macOS, hostState: VMHostState(tags: [work.id]))
        // A tag the library does not define is carried by no VM.
        makeInstance(in: harness, name: "Stray", hostState: VMHostState(tags: [UUID()]))
        let filters = [
            VMLibraryFilter(tags: [work.id]), VMLibraryFilter(tags: [lab.id]),
            VMLibraryFilter(guestOSes: [.macOS], tags: [work.id, lab.id]),
        ]
        for filter in filters {
            harness.library.sidebarOptions.filter = filter
            let sidebar = names(in: harness.library.sidebarLayout.sections.last)
            #expect(try listed(harness, VMListQuery(filter: filter)) == sidebar, "\(filter)")
        }
        #expect(try listed(harness, VMListQuery(filter: filters[0])) == ["Both", "Desk"])
        #expect(try listed(harness, VMListQuery(filter: filters[2])) == ["Desk"])
    }

    // MARK: - Smart groups

    @Test("A smart group named by any case or by identifier lists what its sidebar section lists")
    func smartGroupResolves() throws {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)
        let macs = try harness.library.organization.createSmartGroup(
            named: "Mac Lab", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let section = harness.library.sidebarLayout.sections.first { $0.id == .smartGroup(macs.id) }

        let byName = VMListQuery(groups: [VMGroupReference(.smartGroup, named: "mac lab")])
        #expect(try listed(harness, byName) == names(in: section))
        #expect(names(in: section) == ["Zed", "Mac", "Old"])
        #expect(
            try listed(harness, VMListQuery(groups: [VMGroupReference(.smartGroup, named: macs.id.uuidString)]))
                == ["Zed", "Mac", "Old"])
    }

    @Test("A smart group ANDs with the filter flags and orders by --sort")
    func smartGroupAndsWithTheFilter() throws {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)
        try harness.library.organization.createSmartGroup(
            named: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))

        let query = VMListQuery(
            filter: VMLibraryFilter(states: [.stopped]),
            groups: [VMGroupReference(.smartGroup, named: "Macs")], sort: .name)
        #expect(try listed(harness, query) == ["Mac", "Old"])
    }

    @Test("A smart group the library does not list is refused as not found")
    func unknownSmartGroupIsRefused() {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)

        let refused = refusal(harness, VMListQuery(groups: [VMGroupReference(.smartGroup, named: "Nope")]))
        guard case .itemNotFoundOnHost(let item)? = refused else {
            Issue.record("expected a not-found refusal, got \(String(describing: refused))")
            return
        }
        #expect(item == "smart group named \u{201C}Nope\u{201D}")
    }

    @Test("groups lists each smart group in sidebar order with its members in library order")
    func groupsListsSmartGroups() throws {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)
        let running = try harness.library.organization.createSmartGroup(
            named: "Running", filter: VMLibraryFilter(states: [.running]))
        let empty = try harness.library.organization.createSmartGroup(
            named: "Ephemeral Linux", filter: VMLibraryFilter(guestOSes: [.linux], ephemeralOnly: true))

        let groups = try harness.core.groups()

        #expect(groups.map(\.id) == [running.id, empty.id])
        #expect(groups.map(\.name) == ["Running", "Ephemeral Linux"])
        #expect(groups.map(\.kind) == [.smartGroup, .smartGroup])
        #expect(groups.map { $0.members.map(\.name) } == [["Zed", "Alpha"], []])
    }

    // MARK: - Folders

    /// The mixed library's entries by name.
    private func ids(_ harness: Harness) -> [String: UUID] {
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

    @Test("A folder ANDs with the filter flags, keeping its order")
    func folderAndsWithTheFilter() throws {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)
        let byName = ids(harness)
        try harness.library.organization.createFolder(
            named: "Mixed", members: ["Old", "Alpha", "Mac", "Zed"].compactMap { byName[$0] })

        var query = folder("Mixed")
        query.filter = VMLibraryFilter(guestOSes: [.macOS])
        #expect(try listed(harness, query) == ["Old", "Mac", "Zed"])
        query.filter = VMLibraryFilter(states: [.running])
        #expect(try listed(harness, query) == ["Alpha", "Zed"])
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
