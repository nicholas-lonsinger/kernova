import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Synchronization
import Testing

@testable import Kernova

extension SidebarLayout.Context {
    /// A context naming networks by the app's own titling, over `networks`
    /// and no host interfaces.
    static func testing(
        bundledAgentVersion: String? = "2.0", networks: [VMNamedNetwork] = []
    ) -> SidebarLayout.Context {
        SidebarLayout.Context(
            bundledAgentVersion: bundledAgentVersion, networks: networks,
            networkTitle: {
                NetworkModeChoice.title(of: $0, entitlements: .entitled, interfaces: { [] }, networks: networks)
            })
    }
}

/// `choice` as a filter tells it apart, in a library listing every named
/// network.
private func net(_ choice: NetworkModeChoice) -> VMLibraryFilter.Network {
    VMLibraryFilter.Network(choice) { _, _ in true }
}

/// The library section's filter, sort and grouping: the projection they drive,
/// the selection rules that follow it, the menu that sets them, and the
/// sidebar applying them live.
@Suite("Sidebar filter, sort and group", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarFilterSortGroupTests {
    private let preferences = makeTestPreferences()

    private func makeViewModel() -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
    }

    private func vm(
        _ name: String, guestOS: VMGuestOS = .linux, phase: VMLifecyclePhase = .stopped,
        hostState: VMHostState = VMHostState(), snapshots: VMSnapshotManifest = VMSnapshotManifest(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> LibraryEntry {
        .vm(
            VMInstanceFixture.make(
                name: name, guestOS: guestOS, phase: phase, hostState: hostState, snapshots: snapshots,
                mutate: mutate))
    }

    private func shownNames(
        _ entries: [LibraryEntry], _ options: SidebarViewOptions,
        context: SidebarLayout.Context = .testing()
    ) -> [String] {
        let layout = SidebarLayout.project(entries: entries, options: options, context: context)
        return layout.rowKeys.compactMap { key in entries.first { $0.id == key.entryID }?.name }
    }

    private func options(_ filter: VMLibraryFilter) -> SidebarViewOptions {
        SidebarViewOptions(filter: filter)
    }

    // MARK: - Filter through the projection

    @Test("Each attribute narrows the library section by what each VM is")
    func filterAttributes() {
        let baseline = VMSnapshot(name: "Baseline", macAddress: nil)
        let kept = VMSnapshot(name: "Kept", macAddress: nil)
        let entries = [
            vm("Mac", guestOS: .macOS, phase: .running(sessionID: UUID())) {
                $0.lastSeenAgentVersion = "2.0"
            },
            vm("Old Mac", guestOS: .macOS) { $0.lastSeenAgentVersion = "1.0" },
            vm("Bare Mac", guestOS: .macOS) {
                $0.networkEnabled = false
            },
            vm(
                "Ephemeral", phase: .suspended,
                hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id),
                snapshots: VMSnapshotManifest(snapshots: [baseline])),
            vm("Snapshotted", snapshots: VMSnapshotManifest(snapshots: [kept])) {
                $0.networkMode = .hostOnly
            },
        ]

        #expect(shownNames(entries, options(VMLibraryFilter(guestOSes: [.linux]))) == ["Ephemeral", "Snapshotted"])
        #expect(shownNames(entries, options(VMLibraryFilter(states: [.running]))) == ["Mac"])
        #expect(shownNames(entries, options(VMLibraryFilter(states: [.suspended]))) == ["Ephemeral"])
        #expect(shownNames(entries, options(VMLibraryFilter(networks: [net(.none)]))) == ["Bare Mac"])
        #expect(shownNames(entries, options(VMLibraryFilter(networks: [net(.hostOnly)]))) == ["Snapshotted"])
        #expect(shownNames(entries, options(VMLibraryFilter(guestAgents: [.upToDate]))) == ["Mac"])
        #expect(shownNames(entries, options(VMLibraryFilter(guestAgents: [.olderVersion]))) == ["Old Mac"])
        #expect(shownNames(entries, options(VMLibraryFilter(guestAgents: [.neverConnected]))) == ["Bare Mac"])
        #expect(shownNames(entries, options(VMLibraryFilter(ephemeralOnly: true))) == ["Ephemeral"])
        // The Ephemeral baseline is not a snapshot the user took.
        #expect(shownNames(entries, options(VMLibraryFilter(withSnapshotsOnly: true))) == ["Snapshotted"])
        // ANDed: Linux and not Host Only.
        #expect(
            shownNames(entries, options(VMLibraryFilter(guestOSes: [.linux], networks: [net(.shared)])))
                == ["Ephemeral"])
    }

    @Test("A filter hiding every VM lists the no-matches line; no filter lists nothing extra")
    func noMatchesPlaceholder() throws {
        let entries = [vm("Linux")]
        let hidden = SidebarLayout.project(
            entries: entries, options: options(VMLibraryFilter(guestOSes: [.macOS])), context: .testing())
        #expect(hidden.rowKeys.isEmpty)
        #expect(hidden.sections.first?.emptyText == "No matching VMs")

        let tree = SidebarTree()
        _ = tree.update(to: hidden)
        let section = try #require(tree.sections.first)
        #expect((section.children.first as? SidebarPlaceholder)?.text == "No matching VMs")

        // Clearing the filter swaps the placeholder for the rows.
        let changes = tree.update(
            to: .project(entries: entries, options: SidebarViewOptions(), context: .testing()))
        #expect(section.children.count == 1)
        #expect(section.children.first is SidebarRow)
        #expect(changes.children.first?.removed == IndexSet(integer: 0))

        let empty = SidebarLayout.project(entries: [], options: SidebarViewOptions(), context: .testing())
        #expect(empty.sections.first?.emptyText == nil)
    }

    // MARK: - Sort

    @Test("Name sorts A→Z in Finder order")
    func sortByName() {
        let entries = [vm("VM 10"), vm("beta"), vm("VM 2"), vm("Alpha")]
        #expect(
            shownNames(entries, SidebarViewOptions(sort: .name)) == ["Alpha", "beta", "VM 2", "VM 10"])
    }

    @Test("Date created sorts newest first; ties keep the manual order")
    func sortByDateCreated() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            vm("Old") { $0.createdAt = day },
            vm("Twin A") { $0.createdAt = day.addingTimeInterval(60) },
            vm("New") { $0.createdAt = day.addingTimeInterval(120) },
            vm("Twin B") { $0.createdAt = day.addingTimeInterval(60) },
        ]
        #expect(
            shownNames(entries, SidebarViewOptions(sort: .dateCreated)) == ["New", "Twin A", "Twin B", "Old"])
    }

    @Test("Manual keeps the library's order")
    func sortManual() {
        let entries = [vm("C"), vm("A"), vm("B")]
        #expect(shownNames(entries, SidebarViewOptions(sort: .manual)) == ["C", "A", "B"])
    }

    @Test("The detail line states the sort key's value, status under Name and Manual")
    func detailText() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = vm("Running", phase: .running(sessionID: UUID())) { $0.createdAt = created }
        #expect(SidebarSort.name.detail(for: entry) == "Running")
        #expect(SidebarSort.manual.detail(for: entry) == "Running")
        #expect(
            SidebarSort.dateCreated.detail(for: entry)
                == "Created \(created.formatted(date: .abbreviated, time: .omitted))")
    }

    // MARK: - Group

    private func groups(
        _ entries: [LibraryEntry], _ options: SidebarViewOptions,
        context: SidebarLayout.Context = .testing()
    ) -> [(title: String, names: [String])] {
        let layout = SidebarLayout.project(entries: entries, options: options, context: context)
        guard case .groups(let groups) = layout.sections.first?.content else { return [] }
        return groups.groups.map { ($0.title, $0.rows.entries.map(\.name)) }
    }

    @Test("Group by Guest OS and State list each present value in its order, rows sorted within")
    func groupByOSAndState() {
        let entries = [
            vm("Zed", guestOS: .linux),
            vm("Mac", guestOS: .macOS, phase: .suspended),
            vm("Alpha", guestOS: .linux, phase: .running(sessionID: UUID())),
        ]
        let byOS = groups(entries, SidebarViewOptions(sort: .name, grouping: .guestOS))
        #expect(byOS.map(\.title) == ["macOS", "Linux"])
        #expect(byOS.map(\.names) == [["Mac"], ["Alpha", "Zed"]])

        let byState = groups(entries, SidebarViewOptions(grouping: .state))
        // Empty buckets list no header.
        #expect(byState.map(\.title) == ["Running", "Suspended", "Stopped"])
        #expect(byState.map(\.names) == [["Alpha"], ["Mac"], ["Zed"]])
    }

    @Test("Group by Network keeps one header per network, every unlisted one together")
    func groupByNetwork() {
        let lab = VMNamedNetwork(id: UUID(), name: "Lab", kind: .shared)
        // A named network titled like a built-in choice is still its own.
        let lookalike = VMNamedNetwork(id: UUID(), name: "Host Only", kind: .hostOnly)
        let entries = [
            vm("Off") { $0.networkEnabled = false },
            vm("Gone A") { $0.networkMembership = .network(UUID()) },
            vm("Common") { $0.networkMode = .shared },
            vm("Lab VM") { $0.networkMembership = .network(lab.id) },
            vm("Built-in Host Only") { $0.networkMode = .hostOnly },
            vm("Lookalike") {
                $0.networkMode = .hostOnly
                $0.networkMembership = .network(lookalike.id)
            },
            vm("Gone B") {
                $0.networkMode = .hostOnly
                $0.networkMembership = .network(UUID())
            },
        ]
        let byNetwork = groups(
            entries, SidebarViewOptions(grouping: .network), context: .testing(networks: [lab, lookalike]))
        #expect(
            byNetwork.map(\.title) == [
                "Shared Network", "Lab", "Host Only", "Host Only", "Network Not in This Library", "None",
            ])
        #expect(byNetwork[2].names == ["Built-in Host Only"])
        #expect(byNetwork[3].names == ["Lookalike"])
        #expect(byNetwork[4].names == ["Gone A", "Gone B"])
    }

    @Test("Grouping keeps a filter: a group lists only the VMs the filter admits")
    func groupingUnderFilter() {
        let entries = [vm("Mac", guestOS: .macOS), vm("Linux", guestOS: .linux)]
        let grouped = groups(
            entries,
            SidebarViewOptions(filter: VMLibraryFilter(guestOSes: [.linux]), grouping: .guestOS))
        #expect(grouped.map(\.title) == ["Linux"])
    }

    // MARK: - Selection rules

    @Test("A selection lands on its row, clears when hidden, and falls back to the first row when removed")
    func reconciledSelection() {
        let mac = vm("Mac", guestOS: .macOS)
        let linux = vm("Linux")
        let gone = UUID()
        let layout = SidebarLayout.project(
            entries: [mac, linux], options: options(VMLibraryFilter(guestOSes: [.linux])), context: .testing())
        let present: Set<UUID> = [mac.id, linux.id]

        #expect(layout.reconciled(.library(linux.id)) { present.contains($0) } == .library(linux.id))
        #expect(layout.reconciled(.library(mac.id)) { present.contains($0) } == nil)
        #expect(layout.reconciled(.library(gone)) { present.contains($0) } == .library(linux.id))
        #expect(layout.reconciled(nil) { present.contains($0) } == nil)
    }

    @Test("A filter that hides the selected VM clears the selection")
    func filterHidingSelectionClearsIt() {
        let viewModel = makeViewModel()
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.library.admitFixture(name: "Linux", guestOS: .linux)
        viewModel.selectRevealing(mac.id)

        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])

        #expect(viewModel.selection == nil)
    }

    @Test("A grouping moves the selection onto the VM's grouped row")
    func groupingMovesSelectionOntoGroupedRow() {
        let viewModel = makeViewModel()
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.selectRevealing(mac.id)

        viewModel.sidebarOptions.grouping = .guestOS

        #expect(viewModel.selection?.entryID == mac.id)
        #expect(viewModel.selection?.group == SidebarGroupID(rawValue: "guestOS:macOS"))
    }

    @Test("Removing the selected VM selects the first row the filter shows")
    func removalFallsBackToFirstVisibleRow() {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Hidden Mac", guestOS: .macOS)
        let selected = viewModel.library.admitFixture(name: "Selected", guestOS: .linux)
        let other = viewModel.library.admitFixture(name: "Other", guestOS: .linux)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        viewModel.selectRevealing(selected.id)

        viewModel.library.evict(selected)

        #expect(viewModel.selectedID == other.id)
    }

    @Test("An arrival the filter hides is not selected; one it shows is")
    func hiddenArrivalIsNotSelected() async {
        let viewModel = makeViewModel()
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.selectRevealing(mac.id)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])

        let hiddenGate = GatedStep()
        let hidden = viewModel.library.beginGatedArrival(named: "Linux", guestOS: .linux, gate: hiddenGate)
        #expect(viewModel.selectedID == mac.id)

        let shownGate = GatedStep()
        let shown = viewModel.library.beginGatedArrival(named: "Mac 2", guestOS: .macOS, gate: shownGate)
        #expect(viewModel.selectedID == shown.id)

        hiddenGate.release()
        shownGate.release()
        _ = await hidden.settle()
        _ = await shown.settle()
    }

    @Test("Revealing a hidden VM drops only the filter attributes hiding it, then selects it")
    func revealDropsHidingAttributes() {
        let viewModel = makeViewModel()
        let linux = viewModel.library.admitFixture(name: "Linux", guestOS: .linux)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS], states: [.stopped])

        viewModel.selectRevealing(linux.id)

        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter(states: [.stopped]))
        #expect(viewModel.selectedID == linux.id)
    }

    // MARK: - Reorder

    @Test("A drop under a filter lands before the visible neighbor in the manual order")
    func reorderUnderFilter() {
        let entries = [vm("A"), vm("Hidden Mac", guestOS: .macOS), vm("B"), vm("C")]
        let layout = SidebarLayout.project(
            entries: entries, options: options(VMLibraryFilter(guestOSes: [.linux])), context: .testing())
        let visible = layout.rowKeys.map(\.entryID)
        var order = entries.map(\.id)
        let moved = entries[3].id

        // C dropped above B: before B in the manual order, so after Hidden Mac.
        let offset = SidebarLayout.manualOrderOffset(
            moving: moved, toVisibleIndex: 1, amongVisible: visible, in: order)
        order.move(fromOffsets: IndexSet(integer: 3), toOffset: offset ?? 3)

        #expect(order == [entries[0].id, entries[1].id, moved, entries[2].id])
    }

    @Test("Rows drag only under the manual sort")
    func dragOnlyUnderManualSort() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        let row = try #require(outline.item(atRow: 1) as? SidebarRow)

        #expect(controller.outlineView(outline, pasteboardWriterForItem: row) != nil)
        viewModel.sidebarOptions.sort = .name
        #expect(controller.outlineView(outline, pasteboardWriterForItem: row) == nil)
    }

    // MARK: - Menu

    private func menu(
        _ options: SidebarViewOptions, values: [SidebarViewMenu.Value],
        picked: @escaping (SidebarViewOptions) -> Void = { _ in }
    ) -> NSMenu {
        SidebarViewMenu(networkTitle: { $0.rawValue }, apply: picked).menu(options: options, values: values)
    }

    private func value(
        _ guestOS: VMGuestOS = .linux, state: VMStateBucket = .stopped,
        network: VMLibraryFilter.Network = net(.shared), title: String = "Shared Network",
        isEphemeral: Bool = false
    ) -> SidebarViewMenu.Value {
        SidebarViewMenu.Value(
            subject: VMLibraryFilter.Subject(
                guestOS: guestOS, state: state, network: network,
                guestAgent: guestOS == .macOS ? .neverConnected : nil, isEphemeral: isEphemeral,
                hasSnapshots: false),
            networkTitle: title)
    }

    private func picked(_ item: NSMenuItem?) -> SidebarViewOptions? {
        (item?.representedObject as? SidebarViewMenu.Pick)?.options
    }

    @Test("The menu lists each attribute with its value trailing, then grouping, sort, details and clear")
    func menuStructure() {
        let built = menu(SidebarViewOptions(), values: [value()])
        #expect(
            built.items.map(\.title) == [
                "Guest OS", "State", "Network", "Guest Agent", "Other", "", "Group By", "Sort By", "",
                "Show Details", "", "Clear Filters",
            ])
        #expect(built.items[0].badge?.stringValue == "All")
        #expect(built.items[6].badge?.stringValue == "None")
        #expect(built.items[7].badge?.stringValue == "Manual")
        #expect(built.items.last?.isEnabled == false)
        #expect(built.items[6].submenu?.items.map(\.title) == ["Guest OS", "State", "Network", "", "None"])
        #expect(built.items[7].submenu?.items.map(\.title) == ["Name", "Date Created", "", "Manual"])
    }

    @Test("Submenu counts are over the whole library, and a pick toggles that value")
    func menuCountsAndPicks() throws {
        let values = [value(.macOS), value(.linux), value(.linux)]
        let filtered = SidebarViewOptions(filter: VMLibraryFilter(guestOSes: [.macOS]))
        let built = menu(filtered, values: values)
        let guestOS = try #require(built.items[0].submenu)

        #expect(built.items[0].badge?.stringValue == "macOS")
        #expect(guestOS.items.map(\.title) == ["All Guest OSes", "", "macOS", "Linux"])
        #expect(guestOS.items[2].badge?.itemCount == 1)
        #expect(guestOS.items[3].badge?.itemCount == 2)
        #expect(guestOS.items[2].state == .on)
        #expect(picked(guestOS.items[3])?.filter.guestOSes == [.macOS, .linux])
        #expect(picked(guestOS.items[2])?.filter.guestOSes == [])
        #expect(picked(guestOS.items[0])?.filter.isActive == false)
        #expect(built.items.last?.isEnabled == true)
        #expect(picked(built.items.last)?.filter == VMLibraryFilter())
    }

    @Test("State picks one bucket at a time")
    func stateIsSinglePick() throws {
        let built = menu(
            SidebarViewOptions(filter: VMLibraryFilter(states: [.running])), values: [value()])
        let state = try #require(built.items[1].submenu)
        let suspended = try #require(state.items.first { $0.title == "Suspended" })
        #expect(picked(suspended)?.filter.states == [.suspended])
    }

    @Test("Network lists one row per network, every unlisted one a single row, look-alikes apart")
    func networkRowsByNetwork() throws {
        let lookalike = net(.vmnet(.hostOnly, .network(UUID())))
        let values = [
            value(network: net(.none), title: "None"),
            value(network: .unlisted, title: "Network Not in This Library"),
            value(network: net(.shared), title: "Shared Network"),
            value(network: lookalike, title: "None"),
            value(network: .unlisted, title: "Network Not in This Library"),
        ]
        let network = try #require(menu(SidebarViewOptions(), values: values).items[2].submenu)
        #expect(
            network.items.map(\.title) == [
                "All Networks", "", "Shared Network", "None", "Network Not in This Library", "None",
            ])
        #expect(network.items[4].badge?.itemCount == 2)
        #expect(picked(network.items[4])?.filter.networks == [.unlisted])
        #expect(picked(network.items[3])?.filter.networks == [lookalike])
        #expect(picked(network.items[5])?.filter.networks == [net(.none)])
    }

    @Test("A network the filter names but no VM is on stays listed, checked, to turn off")
    func orphanNetworkStaysListed() throws {
        let gone = net(.bridged("en9"))
        let built = menu(
            SidebarViewOptions(filter: VMLibraryFilter(networks: [gone])), values: [value()])
        let network = try #require(built.items[2].submenu)
        let row = try #require(network.items.first { $0.title == gone.rawValue })
        #expect(row.state == .on)
        #expect(picked(row)?.filter.networks == [])
    }

    @Test("Show Details and the group and sort rows set their options")
    func viewPicks() throws {
        let built = menu(SidebarViewOptions(), values: [value()])
        #expect(picked(built.items[9])?.showsDetails == true)
        let group = try #require(built.items[6].submenu)
        #expect(picked(group.items[2])?.grouping == .network)
        let sort = try #require(built.items[7].submenu)
        #expect(picked(sort.items[1])?.sort == .dateCreated)
    }

    // MARK: - Sidebar

    @Test("The header counts what the filter shows, fills its button and names the filters")
    func headerReflectsFilter() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.library.admitFixture(name: "Linux", guestOS: .linux)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        let header = try #require(
            outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarGroupHeaderCellView)

        let labels = allSubviews(NSTextField.self, in: header).map(\.stringValue)
        #expect(labels.contains("1 of 2"))
        let button = try #require(header.filterButton)
        #expect(button.accessibilityLabel() == "Filter and Sort")
        #expect(button.accessibilityValue() as? String == "Guest OS: Linux")
        #expect(outline.numberOfRows == 2)
    }

    @Test("A grouping in place when the sidebar loads lists its rows under open headers")
    func groupedAtLoadOpensHeaders() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.grouping = .guestOS
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))

        #expect(outline.numberOfRows == 3)
        #expect(outline.item(atRow: 1) is SidebarGroupHeader)
        #expect((outline.item(atRow: 2) as? SidebarRow)?.entry.name == "Mac")
    }

    @Test("The filter button stays clear of the header's Show/Hide control")
    func filterButtonClearsShowHide() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        let controller = SidebarViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        let rowView = try #require(outline.rowView(atRow: 0, makeIfNecessary: true))
        controller.view.layoutSubtreeIfNeeded()
        let header = try #require(firstSubview(SidebarGroupHeaderCellView.self, in: rowView))
        let button = try #require(header.filterButton)
        let showHide = try #require(
            rowView.subviews.first { $0.identifier == NSOutlineView.showHideButtonIdentifier })

        // The control the documented `makeView` route captured is the row's.
        #expect((outline as? SidebarOutlineView)?.showHideButton(in: rowView) === showHide)
        #expect(button.convert(button.bounds, to: rowView).maxX <= showHide.frame.minX)
    }

    @Test("Right-clicking the library header opens the filter menu")
    func headerContextMenu() {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()

        let built = controller.contextMenu(forRow: 0)
        #expect(built?.items.first?.title == "Guest OS")
    }

    @Test("A selected VM that stops matching stays listed and selected until the selection moves off it")
    func selectedVMStaysUntilSelectionMoves() async throws {
        let viewModel = makeViewModel()
        let started = viewModel.library.admitFixture(name: "Started")
        let other = viewModel.library.admitFixture(name: "Other")
        viewModel.sidebarOptions.filter = VMLibraryFilter(states: [.stopped])
        viewModel.selectRevealing(started.id)
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        #expect(outline.numberOfRows == 3)

        started.activity.placeForTesting(.running(sessionID: UUID()))
        // Appearing runs the sidebar's sync pass synchronously.
        controller.viewDidAppear()

        #expect(outline.numberOfRows == 3)
        #expect(viewModel.selectedID == started.id)
        #expect((outline.item(atRow: outline.selectedRow) as? SidebarRow)?.entry.vm === started)
        // The header counts only the VMs the filter matches.
        let header = try #require(
            outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarGroupHeaderCellView)
        #expect(allSubviews(NSTextField.self, in: header).map(\.stringValue).contains("1 of 2"))

        viewModel.selectRevealing(other.id)

        // The projection's own observation loop offers no test-facing signal.
        try await waitUntil { outline.numberOfRows == 2 }
        #expect((outline.item(atRow: 1) as? SidebarRow)?.entry.vm === other)
        #expect(viewModel.selectedID == other.id)
    }

    @Test("The layout's counts follow a retained VM's own changes, which its observation tracks")
    func countFollowsRetainedVM() {
        let viewModel = makeViewModel()
        let started = viewModel.library.admitFixture(name: "Started")
        viewModel.library.admitFixture(name: "Other")
        viewModel.sidebarOptions.filter = VMLibraryFilter(states: [.stopped])
        viewModel.selectRevealing(started.id)
        started.activity.placeForTesting(.running(sessionID: UUID()))
        #expect(
            viewModel.sidebarLayout.sections.first?.filterCounts
                == SidebarLayout.FilterCounts(matching: 1, total: 2))

        // The rows stay the same, so only the retained VM's own state can wake
        // the pass that recounts: an observation of the layout must track it.
        let woke = Mutex(false)
        withObservationTracking {
            _ = viewModel.sidebarLayout
        } onChange: {
            woke.withLock { $0 = true }
        }
        started.activity.placeForTesting(.stopped)

        #expect(woke.withLock { $0 })
        #expect(
            viewModel.sidebarLayout.sections.first?.filterCounts
                == SidebarLayout.FilterCounts(matching: 2, total: 2))
    }

    @Test("A filter edit while the selected VM no longer matches hides it and clears the selection")
    func filterEditDropsRetainedVM() {
        let viewModel = makeViewModel()
        let started = viewModel.library.admitFixture(name: "Started")
        viewModel.library.admitFixture(name: "Other")
        viewModel.sidebarOptions.filter = VMLibraryFilter(states: [.stopped])
        viewModel.selectRevealing(started.id)
        started.activity.placeForTesting(.running(sessionID: UUID()))
        #expect(viewModel.sidebarLayout.rowKeys.contains { $0.entryID == started.id })

        viewModel.sidebarOptions.filter.states = [.stopped, .suspended]

        #expect(viewModel.selection == nil)
        #expect(!viewModel.sidebarLayout.rowKeys.contains { $0.entryID == started.id })
    }

    @Test("A sort, grouping or details edit keeps a retained VM listed and selected")
    func viewEditsKeepRetainedVM() {
        for edit: (inout SidebarViewOptions) -> Void in [
            { $0.sort = .name }, { $0.grouping = .state }, { $0.showsDetails = true },
        ] {
            let viewModel = makeViewModel()
            let started = viewModel.library.admitFixture(name: "Started")
            viewModel.library.admitFixture(name: "Other")
            viewModel.sidebarOptions.filter = VMLibraryFilter(states: [.stopped])
            viewModel.selectRevealing(started.id)
            started.activity.placeForTesting(.running(sessionID: UUID()))

            edit(&viewModel.sidebarOptions)

            #expect(viewModel.selectedID == started.id)
            #expect(viewModel.sidebarLayout.rowKeys.contains { $0.entryID == started.id })
        }
    }

    @Test("A reveal through the command core shows a VM the filter hides and selects it")
    func commandRevealUnderFilter() throws {
        let viewModel = makeViewModel()
        let linux = viewModel.library.admitFixture(name: "Linux", guestOS: .linux)
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])

        try viewModel.commands.reveal(.id(linux.id))

        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter())
        #expect(viewModel.selectedID == linux.id)
        #expect(viewModel.sidebarLayout.rowKeys.contains { $0.entryID == linux.id })
    }

    @Test("Show Details adds the detail line to an arrival's row too")
    func arrivalRowShowsDetail() async throws {
        let viewModel = makeViewModel()
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(named: "Arriving", gate: gate)
        viewModel.sidebarOptions.showsDetails = true
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        let cell = try #require(
            outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SidebarArrivalRowCellView)

        #expect(
            allSubviews(NSTextField.self, in: cell).contains {
                !$0.isHidden && $0.stringValue == arrival.displayLabel
            })

        gate.release()
        _ = await arrival.settle()
    }

    // MARK: - State buckets

    @Test("A VM is running while a session is live, and rests where it rests otherwise")
    func stateBucketFollowsLiveness() {
        let session = UUID()
        #expect(VMLifecyclePhase.running(sessionID: session).stateBucket == .running)
        #expect(VMLifecyclePhase.livePaused(sessionID: session).stateBucket == .running)
        #expect(VMLifecyclePhase.suspended.stateBucket == .suspended)
        for resting: VMLifecyclePhase in [.stopped, .initialBoot, .failed(message: "x"), .removed] {
            #expect(resting.stateBucket == .stopped)
        }
    }

    @Test("An operation with no live session is in the bucket it started from, whatever its status")
    func operationWithoutSessionKeepsItsRest() {
        let instance = VMInstanceFixture.make(phase: .stopped)
        // A cold snapshot capture shows "Taking Snapshot" while nothing is live.
        instance.activity.placeForTesting(.operating(.capturingSnapshot(.stopped), from: .stopped))
        #expect(instance.status == .snapshotting)
        #expect(instance.stateBucket == .stopped)

        let suspended = VMInstanceFixture.make(phase: .suspended)
        suspended.activity.placeForTesting(.operating(.deletingSnapshot, from: .suspended))
        #expect(suspended.stateBucket == .suspended)
    }

    @Test("Another copy's hold outranks this copy's view of the VM")
    func heldByAnotherCopyBucket() {
        let instance = VMInstanceFixture.make(phase: .stopped)
        instance.activity.recordOtherCopyHold(heldElsewhere: true)
        #expect(instance.stateBucket == .heldByAnotherCopy)
    }

    @Test("Show Details adds the sort key's value under each name")
    func showDetailsAddsSecondLine() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        let cell = try #require(
            outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SidebarVMRowCellView)
        let detailShown = {
            allSubviews(NSTextField.self, in: cell).contains { !$0.isHidden && $0.stringValue == "Stopped" }
        }
        #expect(!detailShown())

        viewModel.sidebarOptions.showsDetails = true

        try await waitUntil { detailShown() }
    }
}
