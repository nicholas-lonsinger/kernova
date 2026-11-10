import AppKit
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

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
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: VirtualizationHost(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            localImageInspector: LocalRestoreImageInspector(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            bridgedInterfaces: HostBridgedInterfaceProvider(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: makeTestDownloadsDirectory(),
            preferences: preferences,
            vmnetNetworks: VmnetNetworkService.scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
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

    // MARK: - Sort

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

    @Test("The detail line states the sort key's value, status under Name and Manual")
    func detailText() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = vm("Running", phase: .running(sessionID: UUID())) { $0.createdAt = created }
        #expect(VMLibrarySort.name.detail(for: entry, at: Date()) == "Running")
        #expect(VMLibrarySort.manual.detail(for: entry, at: Date()) == "Running")
        #expect(
            VMLibrarySort.dateCreated.detail(for: entry, at: Date())
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
        let lab = VMNamedNetwork(id: UUID(), name: "Lab", kind: .nat)
        // A named network titled like a built-in choice is still its own.
        let lookalike = VMNamedNetwork(id: UUID(), name: "Host Only", kind: .hostOnly)
        let entries = [
            vm("Off") { $0.networkEnabled = false },
            vm("Gone A") { $0.networkMembership = .network(UUID()) },
            vm("Common") { $0.networkMode = .nat },
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
                "NAT \u{2013} Common", "NAT \u{2013} Lab", "Host Only \u{2013} Common", "Host Only \u{2013} Host Only",
                "Network Not in This Library", "None",
            ])
        #expect(byNetwork[2].names == ["Built-in Host Only"])
        #expect(byNetwork[3].names == ["Lookalike"])
        #expect(byNetwork[4].names == ["Gone A", "Gone B"])
    }

    // MARK: - Menu

    private func menu(
        _ options: SidebarViewOptions, values: [SidebarViewMenu.Value],
        picked: @escaping (SidebarViewOptions) -> Void = { _ in }
    ) -> NSMenu {
        SidebarViewMenu(
            networkTitle: { $0.rawValue }, tags: { [] },
            perform: { command in
                if case .editOptions(let edit) = command { picked(options.applying(edit)) }
            }
        ).menu(options: options, values: values)
    }

    private func value(
        _ guestOS: VMGuestOS = .linux, state: VMStateBucket = .stopped,
        network: VMLibraryFilter.Network = net(.nat), title: String = "NAT \u{2013} Common",
        isEphemeral: Bool = false
    ) -> SidebarViewMenu.Value {
        SidebarViewMenu.Value(
            subject: VMLibraryFilter.Subject(
                guestOS: guestOS, state: state, network: network,
                guestAgent: guestOS == .macOS ? .neverConnected : nil, isEphemeral: isEphemeral,
                hasSnapshots: false),
            networkTitle: title)
    }

    /// The options picking `item` leaves default options with.
    private func picked(_ item: NSMenuItem?) -> SidebarViewOptions? {
        guard case .editOptions(let edit)? = (item?.representedObject as? SidebarViewMenu.Pick)?.command else {
            return nil
        }
        return SidebarViewOptions().applying(edit)
    }

    @Test(
        "The menu lists each attribute with its value trailing, then grouping, sort, details, save, new folder and clear"
    )
    func menuStructure() {
        let built = menu(SidebarViewOptions(), values: [value()])
        #expect(
            built.items.map(\.title) == [
                "Guest OS", "State", "Network", "Guest Agent", "Other", "", "Group By", "Sort By", "",
                "Show Details", "", "Save as Smart Group\u{2026}", "New Folder\u{2026}", "Clear Filters",
            ])
        #expect(built.items[11].isEnabled == false)
        #expect(built.items[0].badge?.stringValue == "All")
        #expect(built.items[6].badge?.stringValue == "None")
        #expect(built.items[7].badge?.stringValue == "Manual")
        #expect(built.items.last?.isEnabled == false)
        #expect(built.items[6].submenu?.items.map(\.title) == ["Guest OS", "State", "Network", "", "None"])
        #expect(built.items[7].submenu?.items.map(\.title) == ["Name", "Date Created", "Last Run", "", "Manual"])
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
            value(network: net(.nat), title: "NAT \u{2013} Common"),
            value(network: lookalike, title: "None"),
            value(network: .unlisted, title: "Network Not in This Library"),
        ]
        let network = try #require(menu(SidebarViewOptions(), values: values).items[2].submenu)
        #expect(
            network.items.map(\.title) == [
                "All Networks", "", "NAT \u{2013} Common", "None", "Network Not in This Library", "None",
            ])
        #expect(network.items[4].badge?.itemCount == 2)
        #expect(picked(network.items[4])?.filter.networks == [.unlisted])
        #expect(picked(network.items[3])?.filter.networks == [lookalike])
        #expect(picked(network.items[5])?.filter.networks == [net(.none)])
    }

    @Test("Any Bridged Interface counts every bridged VM, checks each bridged row, and sorts before Automatic")
    func anyBridgedRowsReadThroughAdmission() throws {
        let automatic = net(.bridged(nil))
        let en0 = net(.bridged("en0"))
        let en1 = net(.bridged("en1"))
        let values = [
            value(network: en1, title: "en1"), value(network: automatic, title: "Automatic"),
            value(network: en0, title: "en0"), value(network: en0, title: "en0"), value(),
        ]
        let built = SidebarViewMenu(
            networkTitle: { $0 == .anyBridged ? SidebarLayout.anyBridgedTitle : $0.rawValue }, tags: { [] },
            perform: { _ in }
        ).menu(options: SidebarViewOptions(filter: VMLibraryFilter(networks: [.anyBridged])), values: values)
        let network = try #require(built.items[2].submenu)

        #expect(
            network.items.map(\.title) == [
                "All Networks", "", "NAT \u{2013} Common", SidebarLayout.anyBridgedTitle, "Automatic", "en0", "en1",
            ])
        #expect(network.items[3].badge?.itemCount == 4)
        #expect(network.items[3...].allSatisfy { $0.state == .on })
        #expect(network.items[2].state == .off)
        #expect(SidebarLayout.networkRank(net(.none)) > SidebarLayout.networkRank(en0))
        #expect(SidebarLayout.networkRank(en0) > SidebarLayout.networkRank(automatic))
        #expect(SidebarLayout.networkRank(automatic) > SidebarLayout.networkRank(.anyBridged))
        #expect(SidebarLayout.networkRank(.anyBridged) > SidebarLayout.networkRank(.unlisted))
    }

    @Test("Unchecking a bridged row Any Bridged Interface checks trades it for the other bridged rows")
    func uncheckingUnderAnyBridged() {
        let automatic = net(.bridged(nil))
        let en0 = net(.bridged("en0"))
        let listed = [net(.nat), .anyBridged, automatic, en0]

        #expect(SidebarViewMenu.toggled(en0, in: [.anyBridged], listed: listed) == [automatic])
        #expect(SidebarViewMenu.toggled(.anyBridged, in: [.anyBridged, en0], listed: listed) == [en0])
        #expect(SidebarViewMenu.toggled(automatic, in: [en0], listed: listed) == [en0, automatic])
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

    @Test("The filter button stays clear of the header's Show/Hide control")
    func filterButtonClearsShowHide() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        let controller = SidebarViewController(viewModel: viewModel)
        let window = makeTestWindow(styleMask: [.titled], contentSize: NSSize(width: 260, height: 200))
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

    @Test("A host interface's title follows the host's interfaces from one pass to the next")
    func bridgedTitleFollowsInterfaces() {
        let interfaces = MockBridgedInterfaceProvider()
        let library = makeWiredLibrary(bridgedInterfaces: interfaces)
        library.admitFixture(name: "Bridged") {
            $0.networkMode = .bridged
            $0.bridgedInterfaceIdentifier = "en7"
        }
        library.sidebarOptions.grouping = .network
        let title = { () -> String? in
            guard case .groups(let groups) = library.sidebarLayout.sections.first?.content else { return nil }
            return groups.groups.first?.title
        }
        #expect(title() == "Bridged \u{2013} en7 (unavailable)")

        interfaces.setAvailable([BridgedInterface(identifier: "en7", localizedDisplayName: "Thunderbolt Ethernet")])

        #expect(title() == "Bridged \u{2013} Thunderbolt Ethernet (en7)")
    }

    @Test("VMInfo reports the state bucket by liveness, and the Shortcuts entity reads it")
    func infoCarriesStateBucket() throws {
        let viewModel = makeViewModel()
        let capturing = viewModel.library.admitFixture(name: "Capturing", phase: .stopped)
        capturing.activity.placeForTesting(.operating(.capturingSnapshot(.stopped), from: .stopped))

        let info = try viewModel.commandsLeavingEditsOpen.info(.id(capturing.id))

        #expect(info.status == VMStatus.snapshotting.rawValue)
        #expect(info.stateBucket == .stopped)
        #expect(VMEntity(info).stateGroup == "stopped")
    }

    @Test("A drop lands only among the dragged row's own group")
    func dropListIsTheRowsGroup() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Linux A", guestOS: .linux)
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.library.admitFixture(name: "Linux B", guestOS: .linux)
        viewModel.sidebarOptions.grouping = .guestOS
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        let section = try #require(outline.item(atRow: 0) as? SidebarSection)
        // Section children: [macOS header, Mac, Linux header, Linux A, Linux B].
        let linuxB = try #require(section.children[4] as? SidebarRow)
        #expect(section.children[2] is SidebarGroupHeader)

        #expect(SidebarViewController.list(of: linuxB) == 3..<5)
        let mac = try #require(section.children[1] as? SidebarRow)
        #expect(SidebarViewController.list(of: mac) == 1..<2)
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
