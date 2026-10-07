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
        phase: VMLifecyclePhase = .stopped, hostState: VMHostState = VMHostState(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, library: harness.library,
            preferences: preferences, hostState: hostState, mutate: mutate)
    }

    /// Five VMs that tell every attribute apart, in library order.
    private func makeMixedLibrary(in harness: Harness) {
        makeInstance(in: harness, name: "Zed", guestOS: .macOS, phase: .running(sessionID: UUID()))
        makeInstance(in: harness, name: "Alpha", phase: .running(sessionID: UUID())) {
            $0.applyNetworkMode(.shared)
        }
        makeInstance(in: harness, name: "Mac", guestOS: .macOS, hostState: VMHostState(ephemeralModeEnabled: true))
        makeInstance(in: harness, name: "Build", phase: .suspended) { $0.applyNetworkMode(.hostOnly) }
        makeInstance(in: harness, name: "Old", guestOS: .macOS) { $0.lastSeenAgentVersion = "0.0.1" }
    }

    private func listed(_ harness: Harness, _ query: VMListQuery) throws -> [String] {
        try harness.core.list(query).map(\.name)
    }

    private func names(in section: SidebarLayout.Section?) -> [String] {
        guard case .rows(let rows)? = section?.content else { return [] }
        return rows.entries.map(\.name)
    }

    // MARK: - Order

    @Test("An unconstrained query lists every VM in library order, as list() does")
    func defaultQueryIsTheManualOrder() throws {
        let harness = makeHarness()
        makeMixedLibrary(in: harness)

        #expect(try listed(harness, VMListQuery()) == ["Zed", "Alpha", "Mac", "Build", "Old"])
        #expect(try harness.core.list(VMListQuery()) == harness.core.list())
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

    @Test("A named network given by name or identifier joins the filter's network include-set")
    func networkNamesResolve() throws {
        let harness = makeHarness()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .hostOnly)
        makeInstance(in: harness, name: "Member") {
            $0.applyNetworkMode(.hostOnly)
            $0.networkMembership = .network(lab.id)
        }
        makeInstance(in: harness, name: "Shared") { $0.applyNetworkMode(.shared) }
        makeInstance(in: harness, name: "Offline")

        #expect(try listed(harness, VMListQuery(networkNames: ["lab"])) == ["Member"])
        #expect(try listed(harness, VMListQuery(networkNames: [lab.id.uuidString])) == ["Member"])
        let sharedToo = VMLibraryFilter(networks: [VMLibraryFilter.Network(spelling: "shared")!])
        #expect(try listed(harness, VMListQuery(filter: sharedToo, networkNames: ["Lab"])) == ["Member", "Shared"])

        let refusal = #expect(throws: CommandError.self) {
            try harness.core.list(VMListQuery(networkNames: ["Nowhere"]))
        }
        guard case .itemNotFoundOnHost(let item)? = refusal else {
            Issue.record("expected a not-found refusal, got \(String(describing: refusal))")
            return
        }
        #expect(item.contains("Nowhere"))
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

        let refusal = #expect(throws: CommandError.self) {
            try harness.core.list(VMListQuery(groups: [VMGroupReference(.smartGroup, named: "Nope")]))
        }
        guard case .itemNotFoundOnHost(let item)? = refusal else {
            Issue.record("expected a not-found refusal, got \(String(describing: refusal))")
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
}
