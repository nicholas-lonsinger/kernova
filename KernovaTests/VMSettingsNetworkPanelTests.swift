import AVFoundation
import AppKit
import KernovaKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import Kernova

/// The Network panel's own behavior, drilled into through the shell.
@Suite("VM Settings Network Panel Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMSettingsNetworkPanelTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMSettingsNetworkPanelTests")

    private func makeViewModel(
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
        arpTable: ScriptedARPTable = ScriptedARPTable(),
        entitled: Bool = true
    ) -> VMLibraryViewModel {
        makeSettingsViewModel(
            preferences: preferences, vmnetNetworks: vmnetNetworks, arpTable: arpTable,
            entitled: entitled)
    }

    /// A library whose NAT and Host Only networks stand on known subnets,
    /// over `arpTable` as the host's table.
    private func makeAddressedViewModel(_ arpTable: ScriptedARPTable) -> VMLibraryViewModel {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedSubnets = [
            .common(.nat): .scripted("192.168.64.0"), .common(.hostOnly): .scripted("192.168.128.0"),
        ]
        return makeViewModel(vmnetNetworks: vmnet, arpTable: arpTable)
    }

    // MARK: - Network mode picker

    /// The entry selecting `choice`; entry titles alone repeat across groups.
    private func item(_ choice: NetworkModeChoice, in popUp: NSPopUpButton) -> NSMenuItem? {
        popUp.itemArray.first { ($0.representedObject as? NetworkModeEntry)?.choice == choice }
    }

    /// What the closed picker shows, which is the cell's own item rather than
    /// the selected entry's title.
    private func closedTitle(_ popUp: NSPopUpButton) -> String? {
        (popUp.cell as? NSPopUpButtonCell)?.title
    }

    /// The menu as a reader sees it: `# ` for a section header, `---` for a
    /// separator, two spaces of indent per indentation level.
    private func menuOutline(_ popUp: NSPopUpButton) -> [String] {
        popUp.itemArray.map {
            if $0.isSeparatorItem { return "---" }
            if $0.isSectionHeader { return "# \($0.title)" }
            return String(repeating: "  ", count: $0.indentationLevel) + $0.title
        }
    }

    private static let wiFi = BridgedInterface(identifier: "en0", localizedDisplayName: "Wi-Fi")
    private static let ethernet = BridgedInterface(
        identifier: "en1", localizedDisplayName: "Ethernet")

    private func makeNetworkController(
        networkEnabled: Bool = true,
        mode: VMNetworkMode = .nat,
        bridgedInterfaceIdentifier: String? = nil,
        macAddress: String? = "aa:bb:cc:dd:ee:ff",
        interfaces: MockBridgedInterfaceProvider = MockBridgedInterfaceProvider(),
        entitled: Bool = true,
        membership: VMNetworkMembership = .common,
        isReadOnly: Bool = false,
        phase: VMLifecyclePhase = .stopped,
        holdsSavedState: Bool = false,
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
        viewModel: VMLibraryViewModel? = nil
    ) -> (VMSettingsViewController, VMInstance) {
        // The pane always shows a VM the library holds, and the library is what
        // answers its address and its entitlements — so `vmnetNetworks` and
        // `entitled` reach the panel through the library, never the panel
        // directly.
        let library = viewModel ?? makeViewModel(vmnetNetworks: vmnetNetworks, entitled: entitled)
        let instance = library.library.registerFixture(phase: phase) {
            $0.networkEnabled = networkEnabled
            $0.networkMode = mode
            $0.bridgedInterfaceIdentifier = bridgedInterfaceIdentifier
            $0.networkMembership = membership
            $0.macAddress = macAddress
        }
        if holdsSavedState { try? VMInstanceFixture.writeSaveFile(for: instance) }
        let vc = makeSettingsPane(
            instance: instance, viewModel: library, isReadOnly: isReadOnly,
            bridgedInterfaces: interfaces)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.network)
        return (vc, instance)
    }

    /// Opens the Mode picker the way clicking it does, which is what puts the
    /// host's bridgeable interfaces on the menu — nothing else enumerates them.
    private func openModeMenu(in vc: VMSettingsViewController) throws -> NSPopUpButton {
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        let menu = try #require(popUp.menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        return popUp
    }

    // MARK: - IP Address row

    /// Reads the host's table once and lets the pane repaint from what it
    /// found: the repaint is a main-actor task a published address enqueues,
    /// so it has run once the main queue drains behind it.
    private func readGuestAddresses(_ viewModel: VMLibraryViewModel) async {
        await viewModel.library.guestAddresses.readForTesting()
        await drainMainQueue()
    }

    @Test("A running NAT VM reads not seen, then fills in the address the host saw, on both surfaces")
    func runningNATVMFillsInTheObservedAddress() async throws {
        let arpTable = ScriptedARPTable()
        let viewModel = makeAddressedViewModel(arpTable)
        let (vc, _) = makeNetworkController(
            isReadOnly: true, phase: .running(sessionID: UUID()), viewModel: viewModel)

        #expect(visibleLabel("Not seen on the network", in: vc.view))
        let copy = try #require(firstSubview(CopyValueButton.self, in: vc.view))
        #expect(copy.isHidden)
        #expect(copy.value == nil)

        arpTable.table = [.scripted("192.168.64.10", mac: "aa:bb:cc:dd:ee:ff", expiry: ARPEntry.freshExpiry)]
        await readGuestAddresses(viewModel)

        #expect(visibleLabel("192.168.64.10", in: vc.view))
        #expect(visibleLabel("IP address", in: vc.view))
        #expect(copy.value == "192.168.64.10")
        #expect(!copy.isHidden)
        // The Network card states the same address: nothing else re-renders it,
        // so the fill-in has to reach both.
        vc.showOverview()
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(findLabel(withText: "192.168.64.10", in: card) != nil)
    }

    @Test("A running Host Only VM shows the address the host saw it use on that network")
    func runningHostOnlyVMShowsItsAddress() async throws {
        let viewModel = makeAddressedViewModel(
            ScriptedARPTable([.scripted("192.168.128.5", mac: "aa:bb:cc:dd:ee:ff", expiry: ARPEntry.freshExpiry)]))
        let (vc, _) = makeNetworkController(
            mode: .hostOnly, isReadOnly: true, phase: .running(sessionID: UUID()), viewModel: viewModel)

        await readGuestAddresses(viewModel)

        #expect(visibleLabel("192.168.128.5", in: vc.view))
    }

    @Test("A stopped VM shows no IP Address row, whatever the host table still lists")
    func stoppedVMHidesTheIPAddressRow() async throws {
        let viewModel = makeAddressedViewModel(
            ScriptedARPTable([.scripted("192.168.64.10", mac: "aa:bb:cc:dd:ee:ff", expiry: ARPEntry.freshExpiry)]))
        let (vc, _) = makeNetworkController(viewModel: viewModel)

        await readGuestAddresses(viewModel)

        #expect(!visibleLabel("IP address", in: vc.view))
    }

    @Test("A bridged VM's row reads Assigned by your network")
    func bridgedVMShowsExternalAssignment() throws {
        let (vc, _) = makeNetworkController(
            mode: .bridged, bridgedInterfaceIdentifier: "en0",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"))

        #expect(visibleLabel("Assigned by your network", in: vc.view))
    }

    @Test("An unentitled build shows no IP Address row")
    func unentitledBuildHidesTheIPAddressRow() throws {
        let (vc, _) = makeNetworkController(entitled: false)

        #expect(!visibleLabel("IP address", in: vc.view))
    }

    @Test("Mode None hides the IP Address row with the rest of the card")
    func noneModeHidesTheIPAddressRow() throws {
        let (vc, _) = makeNetworkController(networkEnabled: false)

        #expect(!visibleLabel("IP address", in: vc.view))
    }

    @Test("The Mode picker replaces the networking switch and offers NAT and None")
    func modePickerOffersNATAndNone() throws {
        let (vc, _) = makeNetworkController(entitled: false)
        #expect(containsLabel("Mode", in: vc.view))
        #expect(!containsLabel("Networking Enabled", in: vc.view))

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        // Nothing to edit in a build that cannot create a network: None is
        // last, with no separator after it.
        #expect(menuOutline(popUp) == ["# NAT", "  Common", "---", "None"])
        #expect(closedTitle(popUp) == "NAT \u{2013} Common")
    }

    @Test("An entitled build groups each mode's networks under its header, then None, then the edit entry")
    func entitledPickerGroupsByMode() throws {
        let (vc, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(
                available: [Self.wiFi, Self.ethernet], primary: "en0"))

        let popUp = try openModeMenu(in: vc)
        #expect(
            menuOutline(popUp) == [
                "# NAT", "  Common", "  Isolated",
                "# Host Only", "  Common", "  Isolated",
                "# Bridged", "  Automatic", "  Wi-Fi (en0)", "  Ethernet (en1)",
                "---", "None",
                "---", Self.editNamedNetworks,
            ])
        #expect(item(.hostOnly, in: popUp)?.isEnabled == true)
    }

    @Test("No entry carries a qualifier: no subtitle, no attributed title")
    func entriesCarryNoQualifier() throws {
        let (viewModel, _) = try makeViewModel(listing: [("Lab", .nat)])
        let (vc, _) = makeNetworkController(viewModel: viewModel)
        let popUp = try openModeMenu(in: vc)
        for entry in popUp.itemArray {
            #expect(entry.subtitle == nil)
            #expect(entry.attributedTitle == nil)
        }
    }

    @Test("An unentitled build still reports a host-only VM's mode")
    func unentitledBuildReportsAHostOnlyVM() throws {
        let (vc, _) = makeNetworkController(mode: .hostOnly, entitled: false)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "Host Only \u{2013} Common (unavailable)")
        #expect(
            menuOutline(popUp) == ["# NAT", "  Common", "# Host Only", "  Common (unavailable)", "---", "None"])
        #expect(item(.hostOnly, in: popUp)?.isEnabled == false)
    }

    @Test(
        "The closed picker names the group and the entry of every kind of choice, the entry checked",
        arguments: ClosedTitleCase.allCases)
    func closedTitleNamesGroupAndEntry(_ testCase: ClosedTitleCase) throws {
        let (viewModel, listed) = try makeViewModel(listing: [("Lab", .hostOnly)])
        let choice: NetworkModeChoice
        let expected: String
        switch testCase {
        case .common: (choice, expected) = (.nat, "NAT \u{2013} Common")
        case .isolated: (choice, expected) = (.vmnet(.nat, .isolated), "NAT \u{2013} Isolated")
        case .named: (choice, expected) = (.vmnet(.hostOnly, .network(listed[0].id)), "Host Only \u{2013} Lab")
        case .unlisted:
            (choice, expected) = (.vmnet(.nat, .network(UUID())), "NAT \u{2013} Network Not in This Library")
        case .bridgedAutomatic: (choice, expected) = (.bridged(nil), "Bridged \u{2013} Automatic")
        case .bridgedInterface: (choice, expected) = (.bridged("en0"), "Bridged \u{2013} Wi-Fi (en0)")
        case .none: (choice, expected) = (.none, "None")
        }
        let (vc, _) = makeNetworkController(
            networkEnabled: choice != .none,
            mode: choice.mode ?? .nat,
            bridgedInterfaceIdentifier: {
                if case .bridged(let id) = choice { return id }
                return nil
            }(),
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"),
            membership: {
                if case .vmnet(_, let membership) = choice { return membership }
                return .common
            }(),
            viewModel: viewModel)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == expected)
        let selected = try #require(item(choice, in: popUp))
        #expect(popUp.selectedItem === selected)
        #expect(selected.state == .on)
        #expect(popUp.itemArray.filter { $0.state == .on }.count == 1)
    }

    enum ClosedTitleCase: CaseIterable, Sendable {
        case common, isolated, named, unlisted, bridgedAutomatic, bridgedInterface, none
    }

    // MARK: - Networks of a mode

    /// Selects the entry titled `title` the way a click does.
    private func choose(_ title: String, in popUp: NSPopUpButton) throws {
        let item = try #require(popUp.itemArray.first { $0.title == title })
        popUp.select(item)
        popUp.sendAction(popUp.action, to: popUp.target)
    }

    /// Selects `choice`'s entry the way a click does.
    private func choose(_ choice: NetworkModeChoice, in popUp: NSPopUpButton) throws {
        let entry: NSMenuItem = try #require(item(choice, in: popUp))
        popUp.select(entry)
        popUp.sendAction(popUp.action, to: popUp.target)
    }

    /// A library listing `networks`, entitled unless `entitled` says otherwise.
    private func makeViewModel(
        listing networks: [(name: String, kind: VmnetNetworkKind)], entitled: Bool = true
    ) throws -> (VMLibraryViewModel, [VMNamedNetwork]) {
        let viewModel = makeViewModel(entitled: entitled)
        let listed = try networks.map {
            try viewModel.networks.create(name: $0.name, kind: $0.kind, verb: .createNetwork)
        }
        return (viewModel, listed)
    }

    @Test("No row but the picker chooses a network: the isolation switch is gone")
    func noIsolationSwitch() {
        let (vc, _) = makeNetworkController(mode: .hostOnly)
        #expect(firstSwitch(action: "isolationToggled", in: vc.view) == nil)
        #expect(!containsLabel("Isolate from other VMs", in: vc.view))
    }

    @Test("Choosing a mode's isolated entry puts the VM on a network of its own")
    func isolatedEntryWritesTheMembership() throws {
        let (vc, instance) = makeNetworkController(mode: .hostOnly)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        try choose(.vmnet(.hostOnly, .isolated), in: popUp)

        #expect(instance.configuration.networkMode == .hostOnly)
        #expect(instance.configuration.networkMembership == .isolated)
        #expect(instance.configuration.joinsOwnNetwork)
        #expect(closedTitle(popUp) == "Host Only \u{2013} Isolated")
        #expect(item(.vmnet(.hostOnly, .isolated), in: popUp)?.state == .on)
    }

    @Test("Choosing the other mode's common network from an isolated one moves both keys")
    func commonEntryOfTheOtherModeMovesModeAndMembership() throws {
        let (vc, instance) = makeNetworkController(mode: .hostOnly, membership: .isolated)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "Host Only \u{2013} Isolated")

        try choose(.nat, in: popUp)

        #expect(instance.configuration.networkMode == .nat)
        #expect(instance.configuration.networkMembership == .common)
        #expect(closedTitle(popUp) == "NAT \u{2013} Common")
    }

    @Test("An unentitled build offers no isolated entry, but shows a VM already isolated so it can move off")
    func unentitledBuildShowsIsolationOnlyToMoveOff() throws {
        let plain = try #require(settingsNetworkModePopUp(in: makeNetworkController(entitled: false).0.view))
        #expect(!plain.itemTitles.contains { $0.contains("Isolated") })

        let (vc, instance) = makeNetworkController(entitled: false, membership: .isolated)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "NAT \u{2013} Isolated (unavailable)")
        #expect(popUp.selectedItem?.isEnabled == false)

        try choose(.nat, in: popUp)

        #expect(instance.configuration.networkMembership == .common)
        #expect(menuOutline(popUp) == ["# NAT", "  Common", "---", "None"])
    }

    @Test(
        "Beside a saved state, only a move to another network of a NAT VM's mode stays live",
        arguments: [VMNetworkMode.nat, .hostOnly])
    func membershipEntriesStayLiveBesideANATSavedState(mode: VMNetworkMode) throws {
        let (vc, instance) = makeNetworkController(
            mode: mode, isReadOnly: true, phase: .suspended, holdsSavedState: true)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        let kind = try #require(VmnetNetworkKind(mode: mode))
        let isolated = NetworkModeChoice.vmnet(kind, .isolated)
        let otherMode: NetworkModeChoice = mode == .nat ? .hostOnly : .nat

        #expect(popUp.isEnabled == (mode == .nat))
        #expect(item(isolated, in: popUp)?.isEnabled == (mode == .nat))
        #expect(item(otherMode, in: popUp)?.isEnabled == false)
        #expect(popUp.menu?.items.first { $0.title == "None" }?.isEnabled == false)
        guard mode == .nat else { return }

        try choose(isolated, in: popUp)

        #expect(instance.configuration.networkMembership == .isolated)
        #expect(instance.hasSaveFile)
    }

    // MARK: - Named networks

    @Test("The library's named networks follow their mode's common and isolated entries")
    func namedNetworksAreListedUnderTheirMode() throws {
        let (viewModel, _) = try makeViewModel(listing: [("Lab", .nat), ("Build Farm", .hostOnly)])
        let (vc, _) = makeNetworkController(viewModel: viewModel)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(
            menuOutline(popUp) == [
                "# NAT", "  Common", "  Isolated", "  Lab",
                "# Host Only", "  Common", "  Isolated", "  Build Farm",
                "# Bridged", "  Automatic",
                "---", "None",
                "---", Self.editNamedNetworks,
            ])
    }

    static let editNamedNetworks = "Edit Named Networks\u{2026}"

    @Test("A library listing no network still offers Edit Named Networks… last, after a separator")
    func noNamedNetworksStillOffersEdit() throws {
        let (vc, _) = makeNetworkController()
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(Array(menuOutline(popUp).suffix(4)) == ["---", "None", "---", Self.editNamedNetworks])
        #expect(popUp.menu?.items.first { $0.title == Self.editNamedNetworks }?.isEnabled == true)
    }

    @Test("A build that cannot create a named network shows no edit entry, and nothing after None")
    func unentitledBuildShowsNoEditEntry() throws {
        let (vc, _) = makeNetworkController(entitled: false)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(!popUp.itemTitles.contains(Self.editNamedNetworks))
        #expect(menuOutline(popUp).last == "None")
    }

    @Test(
        "Edit Named Networks… opens Settings on the VM's listed network, or on the pane, writing nothing",
        arguments: [true, false])
    func editNamedNetworksOpensSettings(onListedNetwork: Bool) throws {
        let (viewModel, listed) = try makeViewModel(listing: [("Lab", .nat)])
        let membership: VMNetworkMembership = onListedNetwork ? .network(listed[0].id) : .isolated
        let instance = viewModel.library.registerFixture {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.networkMembership = membership
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        var requested: [SettingsDestination] = []
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: false,
            showAppSettings: { requested.append($0) })
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.network)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        let closedBefore = closedTitle(popUp)
        #expect(closedBefore == (onListedNetwork ? "NAT \u{2013} Lab" : "NAT \u{2013} Isolated"))
        let configBefore = instance.configuration

        try choose(Self.editNamedNetworks, in: popUp)

        #expect(requested == [onListedNetwork ? .network(listed[0].id) : .pane(.networks)])
        #expect(instance.configuration == configBefore)
        #expect(closedTitle(popUp) == closedBefore)
        let selected = try #require(item(NetworkModeChoice(configBefore), in: popUp))
        #expect(popUp.selectedItem === selected)
        #expect(selected.state == .on)
        #expect(popUp.menu?.items.first { $0.title == Self.editNamedNetworks }?.state == .off)
    }

    @Test("Choosing a named network of the other mode writes its mode and the membership together")
    func choosingANamedNetworkMovesModeAndMembership() throws {
        let (viewModel, listed) = try makeViewModel(listing: [("Build Farm", .hostOnly)])
        let (vc, instance) = makeNetworkController(viewModel: viewModel)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        try choose(.vmnet(.hostOnly, .network(listed[0].id)), in: popUp)

        #expect(instance.configuration.networkMode == .hostOnly)
        #expect(instance.configuration.networkMembership == .network(listed[0].id))
        #expect(closedTitle(popUp) == "Host Only \u{2013} Build Farm")
        #expect(popUp.titleOfSelectedItem == "Build Farm")
        vc.showOverview()
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(findLabel(withText: "Host Only \u{2013} Build Farm", in: card) != nil)
    }

    @Test("Leaving a named network for the other mode's common network lands whole")
    func leavingANamedNetworkForTheOtherMode() throws {
        let (viewModel, listed) = try makeViewModel(listing: [("Lab", .nat)])
        let (vc, instance) = makeNetworkController(
            membership: .network(listed[0].id), viewModel: viewModel)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "NAT \u{2013} Lab")

        try choose(.hostOnly, in: popUp)

        #expect(instance.configuration.networkMode == .hostOnly)
        #expect(instance.configuration.networkMembership == .common)
    }

    @Test("A VM naming a network the library does not list shows it, disabled, as not in this library")
    func unlistedNetworkShowsAsNotInThisLibrary() throws {
        let (vc, _) = makeNetworkController(membership: .network(UUID()))

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "NAT \u{2013} Network Not in This Library")
        #expect(popUp.titleOfSelectedItem == "Network Not in This Library")
        #expect(popUp.selectedItem?.isEnabled == false)
        // Under its mode's header, after the mode's own entries.
        #expect(
            Array(menuOutline(popUp).prefix(5)) == [
                "# NAT", "  Common", "  Isolated", "  Network Not in This Library", "# Host Only",
            ])
        // Not a listed network, so the edit entry opens the pane on no row.
        #expect(
            popUp.itemArray.first { $0.title == Self.editNamedNetworks }?.representedObject
                as? SettingsDestination == .pane(.networks))
    }

    /// A library whose network list can't be read.
    private func makeUnreadableNetworkListViewModel() throws -> VMLibraryViewModel {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let fileURL = scratch.url.appendingPathComponent("Networks.json")
        try Data("not json".utf8).write(to: fileURL)
        return makeSettingsViewModel(
            preferences: preferences, networks: VMNetworkDirectory(fileURL: fileURL))
    }

    static let unreadableNetworkList = "Network List Can\u{2019}t Be Read"

    @Test("With the network list unreadable, a named network's VM has its mode's disabled entry saying so, checked")
    func unreadableListShowsTheNamedMembershipAsUnreadable() throws {
        let viewModel = try makeUnreadableNetworkListViewModel()
        let (vc, _) = makeNetworkController(membership: .network(UUID()), viewModel: viewModel)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "NAT \u{2013} \(Self.unreadableNetworkList)")
        #expect(popUp.titleOfSelectedItem == Self.unreadableNetworkList)
        #expect(popUp.selectedItem?.isEnabled == false)
        #expect(popUp.selectedItem?.state == .on)
        #expect(
            menuOutline(popUp) == [
                "# NAT", "  Common", "  Isolated", "  \(Self.unreadableNetworkList)",
                "# Host Only", "  Common", "  Isolated", "  \(Self.unreadableNetworkList)",
                "# Bridged", "  Automatic",
                "---", "None",
                "---", Self.editNamedNetworks,
            ])
        vc.showOverview()
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(findLabel(withText: "NAT \u{2013} \(Self.unreadableNetworkList)", in: card) != nil)
    }

    @Test("With the network list unreadable, each vmnet mode shows one disabled entry in its named networks' place")
    func unreadableListOffersNoNamedNetwork() throws {
        let viewModel = try makeUnreadableNetworkListViewModel()
        let (vc, _) = makeNetworkController(viewModel: viewModel)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "NAT \u{2013} Common")
        #expect(
            menuOutline(popUp) == [
                "# NAT", "  Common", "  Isolated", "  \(Self.unreadableNetworkList)",
                "# Host Only", "  Common", "  Isolated", "  \(Self.unreadableNetworkList)",
                "# Bridged", "  Automatic",
                "---", "None",
                "---", Self.editNamedNetworks,
            ])
        let unreadable = popUp.itemArray.filter { $0.title == Self.unreadableNetworkList }
        #expect(unreadable.allSatisfy { !$0.isEnabled })
        // No network to select, so the edit entry opens the pane on no row.
        #expect(
            popUp.itemArray.first { $0.title == Self.editNamedNetworks }?.representedObject
                as? SettingsDestination == .pane(.networks))
    }

    @Test("Renaming the VM's named network re-titles the picker and the card")
    func renamingTheNetworkRetitlesThePicker() async throws {
        let (viewModel, listed) = try makeViewModel(listing: [("Lab", .nat)])
        let (vc, _) = makeNetworkController(
            membership: .network(listed[0].id), viewModel: viewModel)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        try viewModel.commands.renameNetwork("Lab", to: "Staging")

        // The pane repaints from its observation loop, a main-actor task the
        // rename enqueued.
        await drainMainQueue()
        #expect(closedTitle(popUp) == "NAT \u{2013} Staging")
        vc.showOverview()
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(findLabel(withText: "NAT \u{2013} Staging", in: card) != nil)
    }

    @Test("An unentitled build offers no named network, but shows the one a VM is on")
    func unentitledBuildShowsOnlyTheCurrentNamedNetwork() throws {
        let (viewModel, listed) = try makeViewModel(
            listing: [("Lab", .nat), ("Other", .nat)], entitled: false)
        let (vc, _) = makeNetworkController(
            membership: .network(listed[0].id), viewModel: viewModel)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "NAT \u{2013} Lab (unavailable)")
        #expect(popUp.selectedItem?.isEnabled == false)
        #expect(!popUp.itemTitles.contains("Other"))
    }

    @Test("The Isolated paragraph names its mode's Common network")
    func isolatedParagraphNamesTheCommonNetwork() {
        let text = paragraphText(
            VMSettingsNetworkPanelViewController.modeInfoParagraphs(
                offered: [.nat], isolationOffered: true, namedNetworksOffered: false,
                natAddressShown: false, guestOS: .macOS))
        #expect(
            text.contains {
                $0.hasPrefix("Isolated: a network of the guest's own instead of its mode's Common network.")
                    && $0.contains("for NAT, to the internet")
            })
    }

    @Test("The Mode info describes isolation and named networks only where the build offers them")
    func modeInfoDescribesIsolationAndNamedNetworksWhenOffered() throws {
        for entitled in [true, false] {
            let (vc, _) = makeNetworkController(entitled: entitled)
            let button = try #require(infoButton(about: "Mode", in: vc.view))
            let text = paragraphText(button.paragraphs)
            #expect(text.contains { $0.hasPrefix("Isolated:") } == entitled)
            #expect(text.contains { $0.hasPrefix("Named Networks:") } == entitled)
        }
    }

    @Test("Choosing Host Only writes the mode and mints a MAC address")
    func selectingHostOnlyWritesConfigAndMintsAMACAddress() throws {
        // From a VM created with networking off, so the MAC is minted here.
        let (vc, instance) = makeNetworkController(networkEnabled: false, macAddress: nil)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        try choose(.hostOnly, in: popUp)

        #expect(instance.configuration.networkEnabled == true)
        #expect(instance.configuration.networkMode == .hostOnly)
        let mac = try #require(instance.configuration.macAddress)
        #expect(VZMACAddress(string: mac) != nil)
    }

    @Test("An unentitled build offers no bridged entries")
    func unentitledPickerOmitsBridgedEntries() throws {
        let (vc, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]), entitled: false)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(menuOutline(popUp) == ["# NAT", "  Common", "---", "None"])
    }

    @Test("A host with nothing to bridge over shows one disabled placeholder")
    func emptyInterfaceListShowsDisabledPlaceholder() throws {
        let (vc, _) = makeNetworkController()

        let popUp = try openModeMenu(in: vc)
        let placeholder = try #require(
            popUp.menu?.items.first { $0.title == "No Bridgeable Interfaces" })
        #expect(!placeholder.isEnabled)
        // Automatic stays offered: it resolves at start, when an interface may be back.
        #expect(popUp.itemTitles.contains("Automatic"))
    }

    @Test("The interface list is enumerated when the menu opens, and only then")
    func menuRebuildPicksUpNewInterfaces() throws {
        let provider = MockBridgedInterfaceProvider(available: [Self.wiFi])
        let (vc, _) = makeNetworkController(interfaces: provider)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        // A picker nobody has opened carries the fixed entries alone.
        #expect(
            menuOutline(popUp) == [
                "# NAT", "  Common", "  Isolated", "# Host Only", "  Common", "  Isolated",
                "# Bridged", "  Automatic", "---", "None", "---", Self.editNamedNetworks,
            ])

        provider.available = [Self.wiFi, Self.ethernet]
        let menu = try #require(popUp.menu)
        menu.delegate?.menuNeedsUpdate?(menu)

        #expect(popUp.itemTitles.contains("Wi-Fi (en0)"))
        #expect(popUp.itemTitles.contains("Ethernet (en1)"))
    }

    @Test("A bridged VM names its interface before the picker has ever been opened")
    func unopenedPickerStillNamesTheBridgedInterface() throws {
        let (vc, _) = makeNetworkController(
            mode: .bridged, bridgedInterfaceIdentifier: "en0",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"))

        // The menu carries an entry for the current choice without an
        // enumeration, so the closed picker still selects and names it.
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(popUp.titleOfSelectedItem == "Wi-Fi (en0)")
        #expect(closedTitle(popUp) == "Bridged \u{2013} Wi-Fi (en0)")
        vc.showOverview()
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(findLabel(withText: "Bridged \u{2013} Wi-Fi (en0)", in: card) != nil)
    }

    @Test("Choosing None writes the mode and hides the MAC row, leaving Mode to say so")
    func selectingNoneWritesConfigAndEmptiesTheCard() throws {
        let (vc, instance) = makeNetworkController()
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(visibleLabel("MAC address", in: vc.view))

        popUp.selectItem(withTitle: "None")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.networkEnabled == false)
        #expect(!visibleLabel("MAC address", in: vc.view))
        #expect(findLabel(containing: "no network device", in: vc.view) == nil)
    }

    @Test("A VM with no network device builds with only the Mode row showing")
    func noneModeBuildsWithOnlyTheModeRow() throws {
        let (vc, _) = makeNetworkController(networkEnabled: false)
        #expect(!visibleLabel("MAC address", in: vc.view))
        #expect(findLabel(containing: "no network device", in: vc.view) == nil)
        #expect(settingsNetworkModePopUp(in: vc.view).flatMap(closedTitle) == "None")
    }

    @Test("The Mode row carries the network info, and the panel header carries none")
    func modeRowCarriesTheNetworkInfo() {
        let (vc, _) = makeNetworkController()
        #expect(infoButton(about: "Mode", in: vc.view) != nil)
        #expect(infoButton(about: "Network", in: vc.view) == nil)
    }

    @Test(
        "The Mode info describes only the modes the picker offers",
        arguments: [[.nat], [.nat, .hostOnly], [.nat, .hostOnly, .bridged]] as [Set<VMNetworkMode>])
    func modeInfoDescribesOnlyOfferedModes(offered: Set<VMNetworkMode>) {
        let text = paragraphText(
            VMSettingsNetworkPanelViewController.modeInfoParagraphs(
                offered: offered, isolationOffered: false, namedNetworksOffered: false,
                natAddressShown: false, guestOS: .macOS))
        #expect(text.contains { $0.hasPrefix("NAT:") })
        #expect(!text.contains { $0.contains("Shared Network") })
        #expect(text.contains { $0.hasPrefix("Host Only:") } == offered.contains(.hostOnly))
        #expect(text.contains { $0.contains("Bridged") } == offered.contains(.bridged))
    }

    private func paragraphText(_ paragraphs: [InfoPopoverParagraph]) -> [String] {
        paragraphs.map {
            switch $0 {
            case .body(let body), .code(let body): body
            }
        }
    }

    @Test("A build without app-managed networking describes only NAT in the Mode info")
    func unentitledModeInfoDescribesOnlyNAT() throws {
        let (vc, _) = makeNetworkController(entitled: false)
        let button = try #require(infoButton(about: "Mode", in: vc.view))
        let text = paragraphText(button.paragraphs)
        #expect(text.contains { $0.hasPrefix("NAT:") })
        #expect(!text.contains { $0.hasPrefix("Host Only:") })
        #expect(!text.contains { $0.contains("Bridged") })
    }

    /// The NAT paragraph's reach clause, as the Mode info button would show it now.
    private func natReachText(in vc: VMSettingsViewController) throws -> String {
        let button = try #require(infoButton(about: "Mode", in: vc.view))
        return try #require(paragraphText(button.paragraphs).first { $0.hasPrefix("NAT:") })
    }

    @Test("The Mode info points at the IP address row only while it shows the NAT address")
    func natReachClauseFollowsTheIPAddressRow() async throws {
        let arpTable = ScriptedARPTable()
        let viewModel = makeAddressedViewModel(arpTable)
        let (vc, _) = makeNetworkController(
            isReadOnly: true, phase: .running(sessionID: UUID()), viewModel: viewModel)

        #expect(!visibleLabel("192.168.64.10", in: vc.view))
        #expect(try natReachText(in: vc).contains("its address on that subnet"))

        arpTable.table = [.scripted("192.168.64.10", mac: "aa:bb:cc:dd:ee:ff", expiry: ARPEntry.freshExpiry)]
        await readGuestAddresses(viewModel)

        #expect(visibleLabel("192.168.64.10", in: vc.view))
        #expect(try natReachText(in: vc).contains("the address in the IP address row"))
    }

    @Test("A stopped NAT VM's Mode info names no IP address row")
    func stoppedNATVMReachClauseNamesNoRow() throws {
        let (vc, _) = makeNetworkController()

        #expect(!visibleLabel("IP address", in: vc.view))
        #expect(try !natReachText(in: vc).contains("IP address row"))
    }

    @Test("Choosing an interface sets the bridged mode and the interface in one gesture")
    func selectingInterfaceWritesModeAndIdentifier() throws {
        let (vc, instance) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(
                available: [Self.wiFi, Self.ethernet], primary: "en0"))
        let popUp = try openModeMenu(in: vc)

        popUp.selectItem(withTitle: "Ethernet (en1)")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.networkEnabled == true)
        #expect(instance.configuration.networkMode == .bridged)
        #expect(instance.configuration.bridgedInterfaceIdentifier == "en1")
        // The pick's own rebuild keeps the interface a live entry: an interface
        // the user just chose from the open picker is not unavailable.
        let picked = try #require(popUp.menu?.items.first { $0.title == "Ethernet (en1)" })
        #expect(picked.isEnabled)
        #expect(popUp.selectedItem === picked)
        #expect(closedTitle(popUp) == "Bridged \u{2013} Ethernet (en1)")
    }

    @Test("Choosing Automatic clears the persisted interface")
    func selectingAutomaticClearsTheInterface() throws {
        let (vc, instance) = makeNetworkController(
            mode: .bridged, bridgedInterfaceIdentifier: "en1",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi, Self.ethernet]))
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        popUp.selectItem(withTitle: "Automatic")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.networkMode == .bridged)
        #expect(instance.configuration.bridgedInterfaceIdentifier == nil)
    }

    @Test("Going back to NAT keeps the interface for the next bridged choice")
    func selectingNATRemembersTheInterface() throws {
        let (vc, instance) = makeNetworkController(
            mode: .bridged, bridgedInterfaceIdentifier: "en1",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi, Self.ethernet]))
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        try choose(.nat, in: popUp)

        #expect(instance.configuration.networkEnabled == true)
        #expect(instance.configuration.networkMode == .nat)
        #expect(instance.configuration.bridgedInterfaceIdentifier == "en1")
    }

    @Test("An interface the host no longer offers stays visible as the selection")
    func absentPersistedInterfaceRendersAsUnavailable() throws {
        let (vc, _) = makeNetworkController(
            mode: .bridged, bridgedInterfaceIdentifier: "en9",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]))

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        let item = try #require(popUp.menu?.items.first { $0.title == "en9 (unavailable)" })
        #expect(!item.isEnabled)
        #expect(popUp.titleOfSelectedItem == "en9 (unavailable)")
        #expect(closedTitle(popUp) == "Bridged \u{2013} en9 (unavailable)")
    }

    @Test("An interface back on the host names itself in the picker and on the card once the picker opens")
    func interfaceBackOnTheHostRenamesTheCurrentEntry() throws {
        let provider = MockBridgedInterfaceProvider(available: [Self.wiFi])
        let (vc, _) = makeNetworkController(
            mode: .bridged, bridgedInterfaceIdentifier: "en1", interfaces: provider)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "Bridged \u{2013} en1 (unavailable)")

        provider.available = [Self.wiFi, Self.ethernet]
        _ = try openModeMenu(in: vc)

        let current = try #require(item(.bridged("en1"), in: popUp))
        #expect(current.title == "Ethernet (en1)")
        #expect(current.isEnabled)
        #expect(popUp.selectedItem === current)
        #expect(!popUp.itemTitles.contains("en1 (unavailable)"))
        #expect(closedTitle(popUp) == "Bridged \u{2013} Ethernet (en1)")
        vc.showOverview()
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(findLabel(withText: "Bridged \u{2013} Ethernet (en1)", in: card) != nil)
    }

    @Test("An identifier remembered from an earlier bridged choice adds no entry")
    func rememberedInterfaceAddsNoEntryWhileNAT() throws {
        let (vc, _) = makeNetworkController(
            mode: .nat, bridgedInterfaceIdentifier: "en9",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]))

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(popUp.menu?.items.first { $0.title == "en9 (unavailable)" } == nil)
        #expect(closedTitle(popUp) == "NAT \u{2013} Common")
    }

    @Test("An unentitled build still reports a bridged VM's mode")
    func unentitledBuildReportsABridgedVM() throws {
        let (vc, _) = makeNetworkController(mode: .bridged, entitled: false)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "Bridged \u{2013} Automatic (unavailable)")
        #expect(
            menuOutline(popUp) == ["# NAT", "  Common", "# Bridged", "  Automatic (unavailable)", "---", "None"])
        #expect(item(.bridged(nil), in: popUp)?.isEnabled == false)
    }

    @Test("An unentitled build names a VM bridged on an interface the same way in the picker and on the card")
    func unentitledBridgedInterfaceReadsTheSameOnPickerAndCard() throws {
        let (vc, _) = makeNetworkController(
            mode: .bridged, bridgedInterfaceIdentifier: "en0",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"),
            entitled: false)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        let title = try #require(closedTitle(popUp))
        #expect(title == "Bridged \u{2013} Wi-Fi (en0) (unavailable)")
        vc.showOverview()
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(findLabel(withText: title, in: card) != nil)
    }

    @Test("The closed picker is at least as wide as its group-and-entry title, whatever its menu's entries")
    func closedPickerFitsItsCompoundTitle() throws {
        // The narrowest menu: an unentitled NAT VM's, every entry shorter than
        // the title the closed picker shows.
        let (vc, _) = makeNetworkController(entitled: false)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        let title = try #require(closedTitle(popUp))
        #expect(title == "NAT \u{2013} Common")

        // AppKit's own chrome: a plain picker whose one item is that title.
        let reference = NSPopUpButton()
        reference.controlSize = popUp.controlSize
        reference.font = popUp.font
        reference.addItem(withTitle: title)
        #expect(popUp.intrinsicContentSize.width >= reference.intrinsicContentSize.width)
    }

    @Test("VoiceOver reads the closed picker's group-and-entry title")
    func closedPickerAccessibilityValueIsTheCompoundTitle() throws {
        let (vc, _) = makeNetworkController(mode: .hostOnly)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "Host Only \u{2013} Common")
        #expect(spokenValue(of: popUp) == "Host Only \u{2013} Common")

        try choose(.nat, in: popUp)
        #expect(spokenValue(of: popUp) == "NAT \u{2013} Common")
    }

    /// The value of the element VoiceOver reads for `popUp` — the control
    /// itself is ignored in favor of its cell.
    private func spokenValue(of popUp: NSPopUpButton) -> String? {
        (NSAccessibility.unignoredDescendant(of: popUp) as? NSAccessibilityProtocol)?.accessibilityValue() as? String
    }

    @Test("Turning networking on gives a VM without a MAC address a stable one")
    func enablingNetworkingMintsAMACAddress() throws {
        // NAT, from a VM created with networking off.
        let (sharedVC, sharedInstance) = makeNetworkController(
            networkEnabled: false, macAddress: nil,
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"))
        let natPopUp = try #require(settingsNetworkModePopUp(in: sharedVC.view))

        try choose(.nat, in: natPopUp)

        let sharedMAC = try #require(sharedInstance.configuration.macAddress)
        #expect(VZMACAddress(string: sharedMAC) != nil)

        // Bridged, from the same starting state.
        let (bridgedVC, bridgedInstance) = makeNetworkController(
            networkEnabled: false, macAddress: nil,
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"))
        let bridgedPopUp = try openModeMenu(in: bridgedVC)

        bridgedPopUp.selectItem(withTitle: "Wi-Fi (en0)")
        bridgedPopUp.sendAction(bridgedPopUp.action, to: bridgedPopUp.target)

        #expect(bridgedInstance.configuration.bridgedInterfaceIdentifier == "en0")
        let bridgedMAC = try #require(bridgedInstance.configuration.macAddress)
        #expect(VZMACAddress(string: bridgedMAC) != nil)
    }

    @Test("A VM that already carries a MAC address keeps it")
    func enablingNetworkingKeepsAnExistingMACAddress() throws {
        let (vc, instance) = makeNetworkController(
            networkEnabled: false, macAddress: "aa:bb:cc:dd:ee:ff")
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        try choose(.nat, in: popUp)

        #expect(instance.configuration.macAddress == "aa:bb:cc:dd:ee:ff")
    }

    // MARK: - MAC Address row

    /// Ends editing the way a click outside the field does.
    /// Ends editing through the field's own delegate, so the assertion covers
    /// the wiring as well as the commit.
    @Test("The MAC Address row offers the persisted address in an editable field")
    func macAddressRowIsEditable() throws {
        let (vc, _) = makeNetworkController()

        let field = try #require(editableField("MAC address", in: vc.view))
        #expect(field.stringValue == "aa:bb:cc:dd:ee:ff")
        #expect(findButton(titled: "Generate", in: vc.view) != nil)
    }

    @Test("A typed MAC address is persisted in canonical form")
    func typedMACAddressIsPersistedCanonically() throws {
        let (vc, instance) = makeNetworkController()
        let field = try #require(editableField("MAC address", in: vc.view))

        typeText(" AA:BB:CC:DD:EE:0F ", into: field)
        commitEdit(field)

        #expect(instance.configuration.macAddress == "aa:bb:cc:dd:ee:0f")
        #expect(field.stringValue == "aa:bb:cc:dd:ee:0f")
    }

    @Test("A MAC address no guest can use is refused and the field reverts")
    func unusableMACAddressIsRefused() throws {
        // Malformed spellings, then the three that parse but address no
        // station: all-zero, broadcast, and multicast.
        let refused = [
            "aa-bb-cc-dd-ee-ff", "aabbccddeeff", "a:b:c:d:e:f", "aa:bb:cc:dd:ee:fg", "",
            "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "01:00:5e:00:00:01",
        ]
        for text in refused {
            let (vc, instance) = makeNetworkController()
            let field = try #require(editableField("MAC address", in: vc.view))

            typeText(text, into: field)
            commitEdit(field)

            #expect(instance.configuration.macAddress == "aa:bb:cc:dd:ee:ff")
            #expect(field.stringValue == "aa:bb:cc:dd:ee:ff")
        }
    }

    /// A library whose single member, named "Holder", already holds `mac` —
    /// named so a banner reporting it is unambiguous, and wired to a presenter
    /// so a refusal's alert is observable rather than buffered.
    private func makeLibraryHolding(
        _ mac: String, presenter: MockVMLibraryPresenting? = nil
    ) -> VMLibraryViewModel {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(guestOS: .linux) {
            $0.name = "Holder"
            $0.macAddress = mac
        }
        if let presenter { viewModel.presenter = presenter }
        return viewModel
    }

    @Test("A MAC address another VM holds is refused and the field reverts")
    func macAddressHeldByAnotherVMIsRefused() throws {
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeLibraryHolding("aa:bb:cc:dd:ee:0f", presenter: presenter)
        let (vc, instance) = makeNetworkController(viewModel: viewModel)
        let field = try #require(editableField("MAC address", in: vc.view))

        typeText("AA:BB:CC:DD:EE:0F", into: field)
        commitEdit(field)

        #expect(instance.configuration.macAddress == "aa:bb:cc:dd:ee:ff")
        #expect(field.stringValue == "aa:bb:cc:dd:ee:ff")
        #expect(presenter.errorTitle == "MAC Address In Use")
    }

    /// The pane opened while the VM was stopped; the start lands while an edit
    /// is still in the field, and the commit comes after it.
    @Test("A MAC address committed after the VM started is refused and changes nothing")
    func macEditCommittedAfterAStartIsRefused() throws {
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeViewModel()
        viewModel.presenter = presenter
        let (vc, instance) = makeNetworkController(viewModel: viewModel)
        let storage = try #require(viewModel.storageService as? MockVMStorageService)
        let before = instance.configuration
        let onDisk = storage.bundles[instance.bundleURL]
        let field = try #require(editableField("MAC address", in: vc.view))
        typeText("aa:bb:cc:dd:ee:01", into: field)

        instance.activity.placeForTesting(.running(sessionID: UUID()))
        commitEdit(field)

        #expect(instance.configuration == before)
        #expect(storage.bundles[instance.bundleURL] == onDisk)
        #expect(presenter.errors.count == 1)
        #expect(presenter.errors.first?.contains("network.mac") == true)
        #expect(field.stringValue == "aa:bb:cc:dd:ee:ff")
    }

    @Test("A refused MAC end-edit puts the model's address back in a field whose editor is still attached")
    func refusedMACEndEditRevertsAFieldStillBeingEdited() throws {
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeViewModel()
        viewModel.presenter = presenter
        let (vc, instance) = makeNetworkController(viewModel: viewModel)
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("MAC address", in: vc.view))
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil)
        typeText("aa:bb:cc:dd:ee:01", into: field)

        instance.activity.placeForTesting(.running(sessionID: UUID()))
        // The refresh the start makes leaves the typed address to its end-edit.
        vc.viewDidAppear()
        #expect(field.currentEditor()?.string == "aa:bb:cc:dd:ee:01")
        commitEdit(field)

        #expect(presenter.errors.count == 1)
        #expect(field.stringValue == instance.configuration.macAddress)
    }

    private static let duplicateMACBanner =
        "\u{201C}Holder\u{201D} also uses this MAC address. Virtual machines with the same "
        + "MAC address can\u{2019}t run on the same network at once, but they can on separate networks."

    @Test("The Network section names another VM holding this VM's MAC address")
    func networkSectionDisclosesADuplicateMACAddress() {
        let viewModel = makeLibraryHolding("aa:bb:cc:dd:ee:ff")
        let (vc, _) = makeNetworkController(viewModel: viewModel)

        #expect(visibleLabel(Self.duplicateMACBanner, in: vc.view))
    }

    @Test("No duplicate-MAC banner when the address is this VM's alone")
    func networkSectionHasNoBannerForAUniqueMACAddress() {
        let viewModel = makeLibraryHolding("aa:bb:cc:dd:ee:0f")
        let (vc, _) = makeNetworkController(viewModel: viewModel)

        #expect(!containsLabel(Self.duplicateMACBanner, in: vc.view))
    }

    @Test("No duplicate-MAC banner while this VM has no network device")
    func networkSectionHasNoBannerWithNetworkingOff() {
        let viewModel = makeLibraryHolding("aa:bb:cc:dd:ee:ff")
        let (vc, _) = makeNetworkController(networkEnabled: false, viewModel: viewModel)

        #expect(!containsLabel(Self.duplicateMACBanner, in: vc.view))
    }

    @Test("A refused live mode switch puts the Mode picker back on the VM's mode, offering a network of its own")
    func refusedLiveModeSwitchRevertsThePicker() async throws {
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeLibraryHolding("aa:bb:cc:dd:ee:ff", presenter: presenter)
        // The holder is live on NAT; this VM shares its address on Host Only,
        // which the start guard permits — the two are on different networks.
        let holder = try #require(viewModel.instances.first)
        holder.activity.placeForTesting(.running(sessionID: UUID()))
        let (vc, instance) = makeNetworkController(
            mode: .hostOnly, isReadOnly: true, phase: .running(sessionID: UUID()), viewModel: viewModel)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        try choose(.nat, in: popUp)

        #expect(instance.configuration.networkMode == .hostOnly)
        #expect(closedTitle(popUp) == "Host Only \u{2013} Common")
        #expect(popUp.selectedItem === item(.hostOnly, in: popUp))
        #expect(item(.hostOnly, in: popUp)?.state == .on)
        #expect(item(.nat, in: popUp)?.state == .off)
        // The offer could not be shown here, so the refusal it stood for is.
        try await waitForChange { presenter.errorTitle != nil }
        #expect(presenter.macAddressRemedyRequests.map(\.prompt.offers.count) == [1])
        #expect(presenter.errorTitles == ["Duplicate MAC Address"])
    }

    @Test("Generate discards a typed duplicate instead of refusing it")
    func generateDiscardsATypedDuplicate() throws {
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeLibraryHolding("aa:bb:cc:dd:ee:0f", presenter: presenter)
        let (vc, instance) = makeNetworkController(viewModel: viewModel)
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("MAC address", in: vc.view))
        #expect(window.makeFirstResponder(field))
        typeText("aa:bb:cc:dd:ee:0f", into: field)
        let generate = try #require(findButton(titled: "Generate", in: vc.view))

        generate.sendAction(generate.action, to: generate.target)

        // The generated address supersedes the typed one, so the duplicate is
        // never committed and its refusal never reaches the user.
        let mac = try #require(instance.configuration.macAddress)
        #expect(mac != "aa:bb:cc:dd:ee:0f")
        #expect(field.stringValue == mac)
        #expect(!presenter.showError)
    }

    @Test("Text a real edit session rejects reverts in the field")
    func rejectedEditRevertsThroughTheFieldEditor() throws {
        let (vc, instance) = makeNetworkController()
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("MAC address", in: vc.view))
        #expect(window.makeFirstResponder(field))
        typeText("nonsense", into: field)

        #expect(window.makeFirstResponder(nil))

        #expect(instance.configuration.macAddress == "aa:bb:cc:dd:ee:ff")
        #expect(field.stringValue == "aa:bb:cc:dd:ee:ff")
    }

    @Test("Text a real edit session accepts lands canonically in the field")
    func acceptedEditCanonicalizesThroughTheFieldEditor() throws {
        let (vc, instance) = makeNetworkController()
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("MAC address", in: vc.view))
        #expect(window.makeFirstResponder(field))
        typeText("AA:BB:CC:DD:EE:0F", into: field)

        #expect(window.makeFirstResponder(nil))

        #expect(instance.configuration.macAddress == "aa:bb:cc:dd:ee:0f")
        #expect(field.stringValue == "aa:bb:cc:dd:ee:0f")
    }

    @Test("Choosing None settles an open MAC edit instead of hiding a focused field")
    func hidingTheRowEndsAnOpenMACEdit() throws {
        let (vc, instance) = makeNetworkController()
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("MAC address", in: vc.view))
        #expect(window.makeFirstResponder(field))
        typeText("aa:bb:cc:dd:ee:01", into: field)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        popUp.selectItem(withTitle: "None")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.networkEnabled == false)
        #expect(!visibleLabel("MAC address", in: vc.view))
        #expect(field.currentEditor() == nil)
    }

    @Test("Generate overrides an edit still open in the field")
    func generateOverridesAnOpenEdit() throws {
        let (vc, instance) = makeNetworkController()
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("MAC address", in: vc.view))
        #expect(window.makeFirstResponder(field))
        typeText("aa:bb:cc:dd:ee:01", into: field)
        let generate = try #require(findButton(titled: "Generate", in: vc.view))

        generate.sendAction(generate.action, to: generate.target)

        // Clicking a push button leaves the field first responder, so the
        // generated address has to survive the edit it interrupts.
        let mac = try #require(instance.configuration.macAddress)
        #expect(mac != "aa:bb:cc:dd:ee:01")
        #expect(field.stringValue == mac)
        #expect(window.makeFirstResponder(nil))
        #expect(instance.configuration.macAddress == mac)
    }

    @Test("A focused MAC field nobody typed in follows a CLI set and writes nothing when focus leaves")
    func aFocusedUntypedMACFollowsTheModel() throws {
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeLibraryHolding("aa:bb:cc:dd:ee:0f", presenter: presenter)
        let (vc, instance) = makeNetworkController(viewModel: viewModel)
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("MAC address", in: vc.view))
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil)

        let outcome = viewModel.setConfiguration(
            [ConfigurationEntry(key: "network.mac", value: "aa:bb:cc:dd:ee:01")], on: instance)
        #expect(outcome == .applied)
        // Stands in for the observation pass the write drives.
        vc.viewDidAppear()
        #expect(field.currentEditor()?.string == "aa:bb:cc:dd:ee:01")
        #expect(window.makeFirstResponder(nil))

        #expect(instance.configuration.macAddress == "aa:bb:cc:dd:ee:01")
        #expect(!presenter.showError)
    }

    @Test("Generate mints a fresh locally administered address and shows it")
    func generateMintsALocallyAdministeredAddress() throws {
        let (vc, instance) = makeNetworkController()
        let generate = try #require(findButton(titled: "Generate", in: vc.view))

        generate.sendAction(generate.action, to: generate.target)

        let mac = try #require(instance.configuration.macAddress)
        #expect(mac != "aa:bb:cc:dd:ee:ff")
        let address = try #require(VZMACAddress(string: mac))
        #expect(address.isUnicastAddress)
        #expect(address.isLocallyAdministeredAddress)
        #expect(editableField("MAC address", in: vc.view)?.stringValue == mac)
    }

    @Test("A running VM locks the MAC controls while the picker stays live")
    func runningVMLocksTheMACControls() throws {
        let (vc, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"),
            isReadOnly: true, phase: .running(sessionID: UUID()))

        #expect(editableField("MAC address", in: vc.view)?.isEnabled == false)
        #expect(findButton(titled: "Generate", in: vc.view)?.isEnabled == false)
        #expect(settingsNetworkModePopUp(in: vc.view)?.isEnabled == true)
    }

    @Test("A refresh leaves a MAC address the user is still typing in alone")
    func refreshKeepsAnInProgressMACEdit() throws {
        let (vc, _) = makeNetworkController()
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("MAC address", in: vc.view))
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil)
        typeText("aa:bb:cc:dd:ee:0", into: field)

        // Stands in for any observation pass — starting the VM from the toolbar
        // mutates status, which refreshes the whole pane.
        vc.viewDidAppear()

        #expect(field.currentEditor()?.string == "aa:bb:cc:dd:ee:0")
    }

    @Test("A VM given its first MAC address shows it in the row straight away")
    func mintedMACAddressAppearsInTheRow() throws {
        let (vc, instance) = makeNetworkController(networkEnabled: false, macAddress: nil)
        #expect(!visibleLabel("MAC address", in: vc.view))
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        try choose(.nat, in: popUp)

        #expect(visibleLabel("MAC address", in: vc.view))
        #expect(
            editableField("MAC address", in: vc.view)?.stringValue
                == instance.configuration.macAddress)
    }

    @Test("Only a usable MAC address normalizes")
    func normalizedMACAddressAcceptsOnlyUsableAddresses() {
        #expect(GuestMACAddress.normalized("AA:BB:CC:DD:EE:FF") == "aa:bb:cc:dd:ee:ff")
        #expect(GuestMACAddress.normalized(" aa:bb:cc:dd:ee:ff\n") == "aa:bb:cc:dd:ee:ff")
        for text in [
            "aa-bb-cc-dd-ee-ff", "aabbccddeeff", "a:b:c:d:e:f", "aa:bb:cc:dd:ee:fg", "",
            "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "01:00:5e:00:00:01",
        ] {
            #expect(GuestMACAddress.normalized(text) == nil)
        }
    }

    @Test("While a networked VM runs, the picker stays live with None disabled")
    func runningVMKeepsThePickerLiveWithNoneDisabled() throws {
        let (vc, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"),
            isReadOnly: true, phase: .running(sessionID: UUID()))

        let popUp = try openModeMenu(in: vc)
        #expect(popUp.isEnabled)
        #expect(popUp.menu?.items.first { $0.title == "None" }?.isEnabled == false)
        #expect(item(.nat, in: popUp)?.isEnabled == true)
        #expect(item(.hostOnly, in: popUp)?.isEnabled == true)
        #expect(popUp.menu?.items.first { $0.title == "Wi-Fi (en0)" }?.isEnabled == true)
    }

    @Test("The Network lock hint hides while the picker is live, and only then")
    func networkLockHintHidesWhileThePickerIsLive() {
        // The Network panel's hint lives on its panel header, the category being
        // a single section.
        let (liveVC, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"),
            isReadOnly: true, phase: .running(sessionID: UUID()))
        #expect(panelHeaderLockHints(in: liveVC).allSatisfy { $0.isHidden })

        let (savingVC, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]),
            isReadOnly: true, phase: .operating(.saving, from: .running(sessionID: UUID())))
        #expect(panelHeaderLockHints(in: savingVC).allSatisfy { !$0.isHidden })
        #expect(!panelHeaderLockHints(in: savingVC).isEmpty)
    }

    @Test("A live mode switch writes the config from the running picker")
    func runningPickerWritesALiveModeSwitch() throws {
        let (vc, instance) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"),
            isReadOnly: true, phase: .running(sessionID: UUID()))
        let popUp = try openModeMenu(in: vc)

        popUp.selectItem(withTitle: "Wi-Fi (en0)")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.networkMode == .bridged)
        #expect(instance.configuration.bridgedInterfaceIdentifier == "en0")
    }

    @Test("A running VM in None mode keeps the picker locked")
    func runningNoneModeVMKeepsThePickerLocked() throws {
        let (vc, _) = makeNetworkController(
            networkEnabled: false,
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]),
            isReadOnly: true, phase: .running(sessionID: UUID()))
        #expect(settingsNetworkModePopUp(in: vc.view)?.isEnabled == false)
    }

    @Test("Transitional phases lock the picker, and a suspended VM's mode")
    func transitionalStatesLockThePicker() throws {
        for phase: VMLifecyclePhase in [
            .operating(.saving, from: .running(sessionID: UUID())),
            .operating(.bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped),
        ] {
            let (vc, _) = makeNetworkController(
                interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]),
                isReadOnly: true, phase: phase)
            #expect(settingsNetworkModePopUp(in: vc.view)?.isEnabled == false)
        }
        // Suspended carries no live `VZVirtualMachine` — there is no session
        // to hot-swap an attachment on — and its saved state pins the device a
        // mode change would change.
        let (vc, _) = makeNetworkController(
            mode: .hostOnly, interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]),
            isReadOnly: true, phase: .suspended, holdsSavedState: true)
        #expect(settingsNetworkModePopUp(in: vc.view)?.isEnabled == false)
    }

    @Test("A stopped VM keeps the fully editable picker, None included")
    func stoppedVMKeepsTheEditablePicker() throws {
        let (vc, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]))

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(popUp.isEnabled)
        #expect(popUp.menu?.items.first { $0.title == "None" }?.isEnabled == true)
    }

    // MARK: - Lock treatment

    @Test("A live-switchable Network section hides its hint and leaves the Mode row undimmed")
    func liveSwitchableNetworkRowStaysUndimmed() throws {
        let (vc, _) = makeNetworkController(isReadOnly: true, phase: .running(sessionID: UUID()))
        let panel = try #require(vc.panelForTesting(.network))
        let modeRow = try #require(settingsRow(labeled: "Mode", in: panel))
        #expect(rowTitle(of: modeRow)?.textColor == .labelColor)
        #expect(settingsNetworkModePopUp(in: vc.view)?.isEnabled == true)
        #expect(panelHeaderLockHints(in: vc).allSatisfy { $0.isHidden })
    }

    @Test("A stopped VM's Network Mode row dims with the rest of its section")
    func stoppedNetworkModeRowFollowsTheLock() throws {
        let (vc, _) = makeNetworkController(isReadOnly: true, phase: .stopped)
        let panel = try #require(vc.panelForTesting(.network))
        let modeRow = try #require(settingsRow(labeled: "Mode", in: panel))
        #expect(rowTitle(of: modeRow)?.textColor == .disabledControlTextColor)
        #expect(settingsNetworkModePopUp(in: vc.view)?.isEnabled == false)
    }
}
