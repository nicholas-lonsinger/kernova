import AVFoundation
import AppKit
import Testing
import Virtualization

@testable import Kernova

/// The Network panel's own behavior, drilled into through the shell.
@Suite("VM Settings Network Panel Tests", .serialized, .admissionGated)
@MainActor
struct VMSettingsNetworkPanelTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmsettings.network")

    /// The Network panel, for the seams it owns rather than the shell.
    private func networkPanel(in vc: VMSettingsViewController)
        -> VMSettingsNetworkPanelViewController?
    {
        vc.settingsPanelForTesting(.network) as? VMSettingsNetworkPanelViewController
    }

    private func makeViewModel(
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
        entitled: Bool = true
    ) -> VMLibraryViewModel {
        makeSettingsViewModel(
            preferences: preferences, vmnetNetworks: vmnetNetworks, entitled: entitled)
    }

    private func makeInstance(guestOS: VMGuestOS) -> VMInstance {
        makeSettingsInstance(guestOS: guestOS)
    }

    // MARK: - Network mode picker

    private static let wiFi = BridgedInterface(identifier: "en0", localizedDisplayName: "Wi-Fi")
    private static let ethernet = BridgedInterface(
        identifier: "en1", localizedDisplayName: "Ethernet")

    private func makeNetworkController(
        networkEnabled: Bool = true,
        mode: VMNetworkMode = .shared,
        bridgedInterfaceIdentifier: String? = nil,
        macAddress: String? = "aa:bb:cc:dd:ee:ff",
        portForwardingRules: [PortForwardingRule] = [],
        interfaces: MockBridgedInterfaceProvider = MockBridgedInterfaceProvider(),
        entitled: Bool = true,
        isReadOnly: Bool = false,
        phase: VMLifecyclePhase = .stopped,
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
        viewModel: VMLibraryViewModel? = nil
    ) -> (VMSettingsViewController, VMInstance) {
        let config = VMConfiguration(
            name: "Test VM", guestOS: .linux, bootMode: .efi,
            networkEnabled: networkEnabled, networkMode: mode,
            bridgedInterfaceIdentifier: bridgedInterfaceIdentifier, macAddress: macAddress,
            portForwardingRules: portForwardingRules)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, phase: phase)
        // The pane always shows a VM the library holds, and the library's slot
        // declaration is what makes an address derivable — so `vmnetNetworks`
        // reaches the panel through the library, never the panel directly.
        let library = viewModel ?? makeViewModel(vmnetNetworks: vmnetNetworks, entitled: entitled)
        registerSettingsInstance(instance, in: library)
        let vc = VMSettingsViewController(
            instance: instance, viewModel: library, isReadOnly: isReadOnly,
            bridgedInterfaces: interfaces,
            entitlements: EntitlementService(
                reader: MockEntitlementReader(
                    granted: entitled ? ["com.apple.vm.networking"] : [])))
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

    @Test("An entitled Shared VM shows the address its slot reserves")
    func entitledSharedVMShowsReservedAddress() throws {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedAddresses = ["aa:bb:cc:dd:ee:ff": "192.168.64.10"]
        let (vc, _) = makeNetworkController(vmnetNetworks: vmnet)

        #expect(visibleLabel("IP address", in: vc.view))
        #expect(visibleLabel("192.168.64.10", in: vc.view))
    }

    @Test("An entitled Host Only VM shows the address it holds on that network")
    func entitledHostOnlyVMShowsItsAddress() throws {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedAddresses = ["aa:bb:cc:dd:ee:ff": "192.168.128.5"]
        let (vc, _) = makeNetworkController(mode: .hostOnly, vmnetNetworks: vmnet)

        #expect(visibleLabel("192.168.128.5", in: vc.view))
    }

    @Test("A not-yet-derivable address renders as a placeholder, then fills in on its own")
    func pendingAddressShowsPlaceholderAndFillsIn() async throws {
        let vmnet = MockVmnetNetworkProvider()
        // A machine that has never created this network: nothing derives an
        // address until the registry learns its addressing.
        vmnet.knownAddressingKinds = []
        let viewModel = makeViewModel(vmnetNetworks: vmnet)
        let (vc, _) = makeNetworkController(vmnetNetworks: vmnet, viewModel: viewModel)

        #expect(visibleLabel("—", in: vc.view))
        vmnet.scriptedAddresses = ["aa:bb:cc:dd:ee:ff": "192.168.64.9"]
        await viewModel.library.networkSlots.addressingLearnTaskForTesting(.shared)?.value
        // The learn's generation bump reaches the pane through its observation
        // loop, which applies on the next main-actor turn.
        for _ in 0..<5 { await Task.yield() }

        #expect(vmnet.materializeCount == 1)
        #expect(visibleLabel("192.168.64.9", in: vc.view))
        // The Network card states the same address: nothing else re-renders it
        // for an idle stopped VM, so the fill-in has to reach both.
        vc.showOverview()
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(findLabel(withText: "192.168.64.9", in: card) != nil)
    }

    @Test("A failed learn leaves the placeholder without spinning the refresh loop")
    func failedLearnLeavesPlaceholder() async throws {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.knownAddressingKinds = []
        vmnet.materializeFails = true
        let viewModel = makeViewModel(vmnetNetworks: vmnet)
        let (vc, _) = makeNetworkController(vmnetNetworks: vmnet, viewModel: viewModel)

        await viewModel.library.networkSlots.addressingLearnTaskForTesting(.shared)?.value
        for _ in 0..<5 { await Task.yield() }

        #expect(visibleLabel("—", in: vc.view))
        #expect(vmnet.materializeCount == 1)
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

    @Test("The Mode picker replaces the networking switch and offers Shared Network and None")
    func modePickerOffersSharedAndNone() throws {
        let (vc, _) = makeNetworkController(entitled: false)
        #expect(containsLabel("Mode", in: vc.view))
        #expect(!containsLabel("Networking Enabled", in: vc.view))

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(popUp.itemTitles == ["Shared Network", "None"])
        #expect(popUp.titleOfSelectedItem == "Shared Network")
    }

    @Test("An entitled build lists a Bridged section with Automatic and each interface")
    func entitledPickerListsBridgedInterfaces() throws {
        let (vc, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(
                available: [Self.wiFi, Self.ethernet], primary: "en0"))

        let popUp = try openModeMenu(in: vc)
        #expect(
            popUp.itemTitles == [
                "Shared Network", "Host Only", "None", "Bridged", "Automatic", "Wi-Fi (en0)",
                "Ethernet (en1)",
            ])
        let header = try #require(popUp.menu?.items.first { $0.title == "Bridged" })
        #expect(header.isSectionHeader)
    }

    @Test("An entitled build offers Host Only between Shared Network and None")
    func entitledPickerOffersHostOnly() throws {
        let (vc, _) = makeNetworkController()

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        let titles = popUp.itemTitles
        let hostOnly = try #require(titles.firstIndex(of: "Host Only"))
        let shared = try #require(titles.firstIndex(of: "Shared Network"))
        let none = try #require(titles.firstIndex(of: "None"))
        #expect(hostOnly == shared + 1)
        #expect(hostOnly < none)
        #expect(popUp.menu?.items.first { $0.title == "Host Only" }?.isEnabled == true)
    }

    @Test("An unentitled build still reports a host-only VM's mode")
    func unentitledBuildReportsAHostOnlyVM() throws {
        let (vc, _) = makeNetworkController(mode: .hostOnly, entitled: false)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(popUp.titleOfSelectedItem == "Host Only (unavailable)")
        #expect(
            popUp.menu?.items.first { $0.title == "Host Only (unavailable)" }?.isEnabled == false)
        #expect(popUp.menu?.items.first { $0.title == "Host Only" } == nil)
    }

    @Test("Choosing Host Only writes the mode and mints a MAC address")
    func selectingHostOnlyWritesConfigAndMintsAMACAddress() throws {
        // From a VM created with networking off, so the MAC is minted here.
        let (vc, instance) = makeNetworkController(networkEnabled: false, macAddress: nil)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        popUp.selectItem(withTitle: "Host Only")
        popUp.sendAction(popUp.action, to: popUp.target)

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
        #expect(popUp.itemTitles == ["Shared Network", "None"])
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
        #expect(popUp.itemTitles == ["Shared Network", "Host Only", "None", "Bridged", "Automatic"])

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

        // The row and the card both read the picker's title, so the menu
        // carries an entry for the current choice without an enumeration.
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(popUp.titleOfSelectedItem == "Wi-Fi (en0)")
        vc.showOverview()
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(findLabel(withText: "Wi-Fi (en0)", in: card) != nil)
    }

    @Test("Choosing None writes the mode, hides the MAC row, and says there's no device")
    func selectingNoneWritesConfigAndEmptiesTheCard() throws {
        let (vc, instance) = makeNetworkController()
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(visibleLabel("MAC address", in: vc.view))

        popUp.selectItem(withTitle: "None")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.networkEnabled == false)
        #expect(!visibleLabel("MAC address", in: vc.view))
        #expect(visibleLabel("This virtual machine has no network device.", in: vc.view))
    }

    @Test("A VM with no network device builds with the caption already showing")
    func noneModeBuildsWithTheCaptionShowing() throws {
        let (vc, _) = makeNetworkController(networkEnabled: false)
        #expect(!visibleLabel("MAC address", in: vc.view))
        #expect(visibleLabel("This virtual machine has no network device.", in: vc.view))
        #expect(settingsNetworkModePopUp(in: vc.view)?.titleOfSelectedItem == "None")
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
        #expect(popUp.titleOfSelectedItem == "Ethernet (en1)")
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

    @Test("Going back to Shared Network keeps the interface for the next bridged choice")
    func selectingSharedRemembersTheInterface() throws {
        let (vc, instance) = makeNetworkController(
            mode: .bridged, bridgedInterfaceIdentifier: "en1",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi, Self.ethernet]))
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))

        popUp.selectItem(withTitle: "Shared Network")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.networkEnabled == true)
        #expect(instance.configuration.networkMode == .shared)
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
    }

    @Test("An identifier remembered from an earlier bridged choice adds no entry")
    func rememberedInterfaceAddsNoEntryWhileShared() throws {
        let (vc, _) = makeNetworkController(
            mode: .shared, bridgedInterfaceIdentifier: "en9",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]))

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(popUp.menu?.items.first { $0.title == "en9 (unavailable)" } == nil)
        #expect(popUp.titleOfSelectedItem == "Shared Network")
    }

    @Test("An unentitled build still reports a bridged VM's mode")
    func unentitledBuildReportsABridgedVM() throws {
        let (vc, _) = makeNetworkController(mode: .bridged, entitled: false)

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(popUp.titleOfSelectedItem == "Bridged (unavailable)")
        #expect(popUp.menu?.items.first { $0.title == "Bridged (unavailable)" }?.isEnabled == false)
    }

    @Test("Turning networking on gives a VM without a MAC address a stable one")
    func enablingNetworkingMintsAMACAddress() throws {
        // Shared Network, from a VM created with networking off.
        let (sharedVC, sharedInstance) = makeNetworkController(
            networkEnabled: false, macAddress: nil,
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"))
        let sharedPopUp = try #require(settingsNetworkModePopUp(in: sharedVC.view))

        sharedPopUp.selectItem(withTitle: "Shared Network")
        sharedPopUp.sendAction(sharedPopUp.action, to: sharedPopUp.target)

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

        popUp.selectItem(withTitle: "Shared Network")
        popUp.sendAction(popUp.action, to: popUp.target)

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

        field.stringValue = " AA:BB:CC:DD:EE:0F "
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

            field.stringValue = text
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
        let holder = makeInstance(guestOS: .linux)
        holder.configuration.name = "Holder"
        holder.configuration.macAddress = mac
        viewModel.instances = [holder]
        if let presenter { viewModel.presenter = presenter }
        return viewModel
    }

    @Test("A MAC address another VM holds is refused and the field reverts")
    func macAddressHeldByAnotherVMIsRefused() throws {
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeLibraryHolding("aa:bb:cc:dd:ee:0f", presenter: presenter)
        let (vc, instance) = makeNetworkController(viewModel: viewModel)
        let field = try #require(editableField("MAC address", in: vc.view))

        field.stringValue = "AA:BB:CC:DD:EE:0F"
        commitEdit(field)

        #expect(instance.configuration.macAddress == "aa:bb:cc:dd:ee:ff")
        #expect(field.stringValue == "aa:bb:cc:dd:ee:ff")
        #expect(presenter.errorTitle == "MAC Address In Use")
    }

    private static let duplicateMACBanner =
        "This MAC address is also used by “Holder”. Each virtual machine needs its own."

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

    @Test("A refused live mode switch puts the Mode picker back on the VM's mode")
    func refusedLiveModeSwitchRevertsThePicker() throws {
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeLibraryHolding("aa:bb:cc:dd:ee:ff", presenter: presenter)
        // The holder is live on Shared; this VM shares its address on Host Only,
        // which the start guard permits — the two are on different networks.
        let holder = try #require(viewModel.instances.first)
        holder.enter(.running(sessionID: UUID()))
        let (vc, instance) = makeNetworkController(
            mode: .hostOnly, isReadOnly: true, phase: .running(sessionID: UUID()), viewModel: viewModel)
        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        let shared = try #require(popUp.itemArray.first { $0.title == "Shared Network" })

        popUp.select(shared)
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.networkMode == .hostOnly)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
        #expect(popUp.titleOfSelectedItem == "Host Only")
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
        try #require(field.currentEditor()).string = "aa:bb:cc:dd:ee:0f"
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
        try #require(field.currentEditor()).string = "nonsense"

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
        try #require(field.currentEditor()).string = "AA:BB:CC:DD:EE:0F"

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
        try #require(field.currentEditor()).string = "aa:bb:cc:dd:ee:01"
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
        try #require(field.currentEditor()).string = "aa:bb:cc:dd:ee:01"
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
        let editor = try #require(field.currentEditor())
        editor.string = "aa:bb:cc:dd:ee:0"

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

        popUp.selectItem(withTitle: "Shared Network")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(visibleLabel("MAC address", in: vc.view))
        #expect(
            editableField("MAC address", in: vc.view)?.stringValue
                == instance.configuration.macAddress)
    }

    @Test("Only a usable MAC address normalizes")
    func normalizedMACAddressAcceptsOnlyUsableAddresses() {
        #expect(VMSettingsNetworkPanelViewController.normalizedMACAddress("AA:BB:CC:DD:EE:FF") == "aa:bb:cc:dd:ee:ff")
        #expect(
            VMSettingsNetworkPanelViewController.normalizedMACAddress(" aa:bb:cc:dd:ee:ff\n") == "aa:bb:cc:dd:ee:ff")
        for text in [
            "aa-bb-cc-dd-ee-ff", "aabbccddeeff", "a:b:c:d:e:f", "aa:bb:cc:dd:ee:fg", "",
            "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "01:00:5e:00:00:01",
        ] {
            #expect(VMSettingsNetworkPanelViewController.normalizedMACAddress(text) == nil)
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
        #expect(popUp.menu?.items.first { $0.title == "Shared Network" }?.isEnabled == true)
        #expect(popUp.menu?.items.first { $0.title == "Host Only" }?.isEnabled == true)
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
            isReadOnly: true, phase: .saving(sessionID: UUID()))
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

    @Test("Transitional and suspended phases lock the picker")
    func transitionalStatesLockThePicker() throws {
        for phase in [
            VMLifecyclePhase.saving(sessionID: UUID()), .revertingToSnapshot, .suspended,
        ] {
            // Suspended carries no live `VZVirtualMachine` — there is no
            // session to hot-swap an attachment on.
            let (vc, _) = makeNetworkController(
                interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]),
                isReadOnly: true, phase: phase)
            #expect(settingsNetworkModePopUp(in: vc.view)?.isEnabled == false)
        }
    }

    @Test("A stopped VM keeps the fully editable picker, None included")
    func stoppedVMKeepsTheEditablePicker() throws {
        let (vc, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]))

        let popUp = try #require(settingsNetworkModePopUp(in: vc.view))
        #expect(popUp.isEnabled)
        #expect(popUp.menu?.items.first { $0.title == "None" }?.isEnabled == true)
    }

    // MARK: - Port Forwarding

    private static let webRule = PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80)
    private static let sshRule = PortForwardingRule(transport: .tcp, hostPort: 2222, guestPort: 22)

    @Test("An entitled Shared VM lists its forwarding rules and the Add Rule row")
    func sharedVMListsForwardingRules() {
        let (vc, _) = makeNetworkController(portForwardingRules: [Self.webRule, Self.sshRule])

        #expect(visibleLabel("Port forwarding", in: vc.view))
        #expect(visibleLabel("TCP", in: vc.view))
        #expect(visibleLabel("Host 8080 → Guest 80", in: vc.view))
        #expect(visibleLabel("Host 2222 → Guest 22", in: vc.view))
        #expect(findButton(titled: "Add Rule…", in: vc.view) != nil)
    }

    @Test("A VM with no rules still offers Add Rule")
    func sharedVMWithoutRulesOffersAddRule() {
        let (vc, _) = makeNetworkController()

        #expect(visibleLabel("Port forwarding", in: vc.view))
        #expect(findButton(titled: "Add Rule…", in: vc.view)?.isEnabled == true)
    }

    @Test("Modes and builds that cannot forward show no Port Forwarding rows")
    func nonForwardingModesHideTheRows() {
        // Host Only reaches only this Mac, None has no device, and an
        // unentitled build attaches system NAT — none of them forwards.
        let (hostOnly, _) = makeNetworkController(
            mode: .hostOnly, portForwardingRules: [Self.webRule])
        #expect(!visibleLabel("Port forwarding", in: hostOnly.view))

        let (none, _) = makeNetworkController(
            networkEnabled: false, portForwardingRules: [Self.webRule])
        #expect(!visibleLabel("Port forwarding", in: none.view))

        let (unentitled, _) = makeNetworkController(
            portForwardingRules: [Self.webRule], entitled: false)
        #expect(!visibleLabel("Port forwarding", in: unentitled.view))
    }

    @Test("Removing a rule writes the configuration without it")
    func removingARuleWritesTheRemainder() throws {
        let (vc, instance) = makeNetworkController(
            portForwardingRules: [Self.webRule, Self.sshRule])
        let remove = try #require(removeRuleButtons(in: vc.view).first)

        remove.performClick(nil)

        #expect(instance.configuration.portForwardingRules == [Self.sshRule])
        #expect(!visibleLabel("Host 8080 → Guest 80", in: vc.view))
        #expect(visibleLabel("Host 2222 → Guest 22", in: vc.view))
    }

    @Test("A running VM's rule controls are locked")
    func runningVMLocksTheRuleControls() {
        let (vc, _) = makeNetworkController(
            portForwardingRules: [Self.webRule], isReadOnly: true, phase: .running(sessionID: UUID()))

        #expect(removeRuleButtons(in: vc.view).allSatisfy { !$0.isEnabled })
        #expect(findButton(titled: "Add Rule…", in: vc.view)?.isEnabled == false)
    }

    @Test("Unlocking after a session re-enables the rule controls")
    func unlockingReenablesTheRuleControls() {
        let (vc, instance) = makeNetworkController(
            portForwardingRules: [Self.webRule], isReadOnly: true, phase: .running(sessionID: UUID()))
        #expect(findButton(titled: "Add Rule…", in: vc.view)?.isEnabled == false)

        vc.reconfigure(instance: instance, viewModel: makeViewModel(), isReadOnly: false)

        #expect(findButton(titled: "Add Rule…", in: vc.view)?.isEnabled == true)
        #expect(removeRuleButtons(in: vc.view).allSatisfy { $0.isEnabled })
    }

    @Test("Host port claims cover every VM's rules, whatever mode each VM is in")
    func hostPortClaimsSpanEveryMode() {
        let viewModel = makeViewModel()
        // A rule persists across a mode switch and takes its host port back on
        // the way in, so a Host Only VM still holds the claim.
        let hostOnly = makeInstance(guestOS: .linux)
        hostOnly.configuration.networkMode = .hostOnly
        hostOnly.configuration.portForwardingRules = [Self.sshRule]
        let disabled = makeInstance(guestOS: .linux)
        disabled.configuration.networkEnabled = false
        disabled.configuration.portForwardingRules = [
            PortForwardingRule(transport: .udp, hostPort: 5353, guestPort: 53)
        ]
        viewModel.instances = [hostOnly, disabled]

        let (vc, _) = makeNetworkController(
            portForwardingRules: [Self.webRule], viewModel: viewModel)

        #expect(
            networkPanel(in: vc)?.takenHostPortClaimsForTesting == [
                Self.webRule.hostClaim, Self.sshRule.hostClaim,
                PortForwardingHostClaim(transport: .udp, hostPort: 5353),
            ])
    }

    private func removeRuleButtons(in view: NSView) -> [NSButton] {
        allSubviews(NSButton.self, in: view) { $0.toolTip == "Remove Rule" }
    }

    // MARK: - Lock treatment

    @Test("A live-switchable Network section hides its hint and leaves the Mode row undimmed")
    func liveSwitchableNetworkRowStaysUndimmed() throws {
        let (vc, _) = makeNetworkController(isReadOnly: true, phase: .running(sessionID: UUID()))
        let panel = try #require(vc.panelForTesting(.network))
        let modeRow = try #require(settingsRow(labeled: "Mode", in: panel))
        #expect(modeRow.alphaValue == 1)
        #expect(settingsNetworkModePopUp(in: vc.view)?.isEnabled == true)
        #expect(panelHeaderLockHints(in: vc).allSatisfy { $0.isHidden })
    }

    @Test("A stopped VM's Network Mode row dims with the rest of its section")
    func stoppedNetworkModeRowFollowsTheLock() throws {
        let (vc, _) = makeNetworkController(isReadOnly: true, phase: .stopped)
        let panel = try #require(vc.panelForTesting(.network))
        let modeRow = try #require(settingsRow(labeled: "Mode", in: panel))
        #expect(modeRow.alphaValue == Alpha.disabled)
    }
}
