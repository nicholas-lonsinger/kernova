import AVFoundation
import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The Network panel's own behavior, drilled into through the shell.
@Suite("VM Settings Network Panel Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMSettingsNetworkPanelTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMSettingsNetworkPanelTests")

    private func makeViewModel(
        vmnetNetworks: VmnetNetworkService = .scripted(),
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
        let vmnet = ScriptedVmnetNetworks()
        vmnet.join(.common(.nat), on: "192.168.64.0")
        vmnet.join(.common(.hostOnly), on: "192.168.128.0")
        return makeViewModel(vmnetNetworks: vmnet.service, arpTable: arpTable)
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
        vmnetNetworks: VmnetNetworkService = .scripted(),
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

        arpTable.setTable([.scripted("192.168.64.10", mac: "aa:bb:cc:dd:ee:ff", expiry: ARPEntry.freshExpiry)])
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

    static let editNamedNetworks = "Edit Named Networks\u{2026}"

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
        viewModel.onShowSettings = { requested.append($0) }
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
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

    /// A library whose network list can't be read.
    private func makeUnreadableNetworkListViewModel() throws -> VMLibraryViewModel {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let fileURL = scratch.url.appendingPathComponent("Networks.json")
        try Data("not json".utf8).write(to: fileURL)
        return makeSettingsViewModel(
            preferences: preferences, networks: VMNetworkDirectory(fileURL: fileURL))
    }

    static let unreadableNetworkList = "Network List Can\u{2019}t Be Read"

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

    private func paragraphText(_ paragraphs: [InfoPopoverParagraph]) -> [String] {
        paragraphs.map(\.text)
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

        arpTable.setTable([.scripted("192.168.64.10", mac: "aa:bb:cc:dd:ee:ff", expiry: ARPEntry.freshExpiry)])
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

    @Test("An interface back on the host names itself in the picker and on the card once the picker opens")
    func interfaceBackOnTheHostRenamesTheCurrentEntry() throws {
        let provider = MockBridgedInterfaceProvider(available: [Self.wiFi])
        let (vc, _) = makeNetworkController(
            mode: .bridged, bridgedInterfaceIdentifier: "en1", interfaces: provider)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(closedTitle(popUp) == "Bridged \u{2013} en1 (unavailable)")

        provider.setAvailable([Self.wiFi, Self.ethernet])
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

    // MARK: - MAC Address row

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
        #expect(presenter.stepRouteRequests.map(\.requirement.routes.count) == [1])
        #expect(presenter.errorTitles == ["Duplicate MAC Address"])
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
        #expect(GuestMACAddress.normalized(mac) == mac)
        #expect(field.stringValue == mac)
        #expect(window.makeFirstResponder(nil))
        #expect(instance.configuration.macAddress == mac)
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
}
