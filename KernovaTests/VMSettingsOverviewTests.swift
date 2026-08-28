import AppKit
import Testing

@testable import Kernova

@Suite("VM Settings Overview Tests", .serialized, .admissionGated)
@MainActor
struct VMSettingsOverviewTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmoverview")

    // MARK: - Fixtures

    private func makeViewModel() -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences
        )
    }

    private func makeInstance(guestOS: VMGuestOS, macAddress: String? = nil) -> VMInstance {
        let config = VMConfiguration(
            name: "Test VM", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi,
            macAddress: macAddress)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    private func makeController(guestOS: VMGuestOS = .macOS, isReadOnly: Bool = false) -> (
        VMSettingsViewController, VMInstance, VMLibraryViewModel
    ) {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: guestOS)
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        return (vc, instance, viewModel)
    }

    /// Stands in for the observation pass that follows a model write.
    private func reapply(_ vc: VMSettingsViewController, _ pair: (VMInstance, VMLibraryViewModel)) {
        vc.reconfigure(instance: pair.0, viewModel: pair.1, isReadOnly: false)
    }

    private func card(_ category: VMSettingsCategory, in vc: VMSettingsViewController) throws
        -> VMOverviewCardView
    {
        try #require(vc.overviewCardForTesting(category))
    }

    private func cardSwitch(_ toggle: VMOverviewToggle, in card: NSView) -> NSSwitch? {
        firstSubview(NSSwitch.self, in: card) { $0.identifier?.rawValue == toggle.rawValue }
    }

    /// The Sharing card's closing line, which opens on the passthrough state.
    private func summaryLine(in card: NSView) -> String? {
        firstSubview(NSTextField.self, in: card) { $0.stringValue.hasPrefix("Passthrough ") }?
            .stringValue
    }

    private func showButton(_ category: VMSettingsCategory, in card: NSView) -> NSButton? {
        firstSubview(NSButton.self, in: card) { $0.toolTip == "Show \(category.title)" }
    }

    private func lockHints(in view: NSView) -> [NSView] {
        allSubviews(NSStackView.self, in: view) { $0.toolTip == groupedFormLockHintText }
    }

    /// The panel header's bezeled back button, which carries no title.
    private func backButton(in header: NSView) -> NSButton? {
        firstSubview(NSButton.self, in: header) { $0.toolTip == "Show all settings" }
    }

    // MARK: - Cards

    @Test("The overview carries one card per category")
    func overviewCarriesEveryCategory() throws {
        let (vc, _, _) = makeController()
        for category in VMSettingsCategory.allCases {
            let card = try self.card(category, in: vc)
            #expect(findLabel(withText: category.title, in: card) != nil)
        }
    }

    @Test("A macOS card set states the input devices and offers drag and drop")
    func macOSCardsCoverGuestOnlyRows() throws {
        let (vc, _, _) = makeController(guestOS: .macOS)

        #expect(findLabel(withText: "Input devices", in: try card(.system, in: vc)) != nil)
        #expect(cardSwitch(.dropFiles, in: try card(.sharing, in: vc)) != nil)
    }

    @Test("A Linux card set drops the macOS-only rows and keeps the clipboard switch")
    func linuxCardsDropMacOSOnlyRows() throws {
        let (vc, _, _) = makeController(guestOS: .linux)
        let sharing = try card(.sharing, in: vc)

        #expect(findLabel(withText: "Input devices", in: try card(.system, in: vc)) == nil)
        #expect(cardSwitch(.dropFiles, in: sharing) == nil)
        #expect(cardSwitch(.clipboardSharing, in: sharing) != nil)
        #expect(summaryLine(in: sharing) != nil)
    }

    // MARK: - Drill-in

    @Test("The card affordance opens its panel and hides the overview; back returns")
    func drillInAndBack() throws {
        let (vc, _, _) = makeController()
        let storageCard = try card(.storage, in: vc)
        let panel = try #require(vc.panelForTesting(.storage))
        #expect(isVisible(storageCard, within: vc.view))
        #expect(!isVisible(panel, within: vc.view))

        let show = try #require(showButton(.storage, in: storageCard))
        show.performClick(nil)

        #expect(vc.selectedCategory == .storage)
        #expect(isVisible(panel, within: vc.view))
        #expect(!isVisible(storageCard, within: vc.view))

        let header = try #require(firstSubview(VMIdentityHeaderView.self, in: vc.view))
        try #require(backButton(in: header)).performClick(nil)

        #expect(vc.selectedCategory == nil)
        #expect(isVisible(storageCard, within: vc.view))
        #expect(!isVisible(panel, within: vc.view))
    }

    @Test("The open category survives a read-only flip and resets on a VM switch")
    func selectionOutlivesAReadOnlyFlipOnly() throws {
        let (vc, instance, viewModel) = makeController()
        vc.showCategory(.network)

        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: true)
        #expect(vc.selectedCategory == .network)

        vc.reconfigure(
            instance: makeInstance(guestOS: .macOS), viewModel: viewModel, isReadOnly: false)

        #expect(vc.selectedCategory == nil)
        // The overview is actually back on screen: a rebuild that only cleared
        // the category would leave it hidden from the previous VM's drill-in,
        // and the pane would come up blank with nothing to click.
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(isVisible(card, within: vc.view))
        for category in VMSettingsCategory.allCases {
            let panel = try #require(vc.panelForTesting(category))
            #expect(!isVisible(panel, within: vc.view))
        }
    }

    @Test("Opening a panel commits an edit in flight instead of hiding its editor")
    func drillInSettlesAnOpenFieldEditor() throws {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: .linux, macAddress: "aa:bb:cc:dd:ee:ff")
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        vc.showCategory(.network)
        let panel = try #require(vc.panelForTesting(.network))
        let field = try #require(findEditableField(in: panel))
        #expect(window.makeFirstResponder(field))
        field.stringValue = "aa:bb:cc:dd:ee:01"

        vc.showOverview()

        // Nothing is left focused inside the hidden panel, so no later keystroke
        // lands in a control the user can't see.
        #expect(field.currentEditor() == nil)
        #expect(instance.configuration.macAddress == "aa:bb:cc:dd:ee:01")
    }

    @Test("A drilled-in header is one row: the way back, the title, the facts trailing")
    func panelHeaderIsOneRowBehindTheBackButton() throws {
        let (vc, instance, _) = makeController()
        let window = makeTestWindow(styleMask: [.titled])
        window.setContentSize(NSSize(width: 700, height: 400))
        window.contentView = vc.view
        let header = try #require(firstSubview(VMIdentityHeaderView.self, in: vc.view))
        vc.view.layoutSubtreeIfNeeded()
        let facts = header.renderedFactsLine
        #expect(!facts.isEmpty)
        // The overview states the VM's name over the same facts line, on its tile.
        #expect(findLabel(withText: instance.name, in: header) != nil)
        let tile = try #require(firstSubview(NSBox.self, in: header))
        #expect(isVisible(tile, within: header))

        vc.showCategory(.system)
        vc.view.layoutSubtreeIfNeeded()

        // The same header, reconfigured — not a second view swapped in.
        #expect(firstSubview(VMIdentityHeaderView.self, in: vc.view) === header)
        let back = try #require(backButton(in: header))
        let title = try #require(findLabel(withText: "System", in: header))
        let factsLabel = try #require(findLabel(withText: facts, in: header))
        #expect(back.accessibilityLabel() == "Back")
        // A real bezeled control in the accent color, not a hand-drawn chevron.
        #expect(back.isBordered)
        #expect(back.bezelStyle == .push)
        #expect(back.contentTintColor == .controlAccentColor)
        #expect(back.frame.size == NSSize(width: 28, height: 24))
        // No tile: the row leads with the button, the title following it.
        #expect(!isVisible(tile, within: header))
        #expect(findLabel(withText: instance.name, in: header) == nil)
        #expect(title.font == Typography.title)
        let backFrame = back.convert(back.bounds, to: header)
        let titleFrame = title.convert(title.bounds, to: header)
        let factsFrame = factsLabel.convert(factsLabel.bounds, to: header)
        #expect(titleFrame.minX > backFrame.maxX)
        // The facts line trails the title on that same row, not below it.
        #expect(factsFrame.minX > titleFrame.maxX)
        #expect(factsFrame.midY > titleFrame.minY)
        #expect(factsFrame.midY < titleFrame.maxY)
    }

    @Test("A single-section panel states its name once, keeping the section's affordances")
    func singleSectionPanelsFoldTheirHeader() throws {
        let (vc, _, _) = makeController()
        for category in [VMSettingsCategory.network, .snapshots] {
            vc.showCategory(category)
            let panel = try #require(vc.panelForTesting(category))
            let header = try #require(firstSubview(VMIdentityHeaderView.self, in: vc.view))

            #expect(findLabel(withText: category.title, in: panel) == nil)
            #expect(findLabel(withText: category.title, in: header) != nil)
            #expect(firstSubview(InfoButtonView.self, in: header) != nil)
        }
        // The Snapshots readout follows its info affordance into the header
        // rather than being orphaned with the section header.
        let snapshots = try #require(firstSubview(SnapshotSectionView.self, in: vc.view))
        let header = try #require(firstSubview(VMIdentityHeaderView.self, in: vc.view))
        #expect(snapshots.sizeReadout.isDescendant(of: header))
    }

    // MARK: - Mirrored toggles

    @Test("A card switch writes the configuration and the panel's own switch follows")
    func cardSwitchWritesAndPanelFollows() throws {
        let (vc, instance, viewModel) = makeController()
        let toggle = try #require(cardSwitch(.autoStart, in: try card(.general, in: vc)))
        #expect(instance.configuration.startsAutomaticallyOnLaunch == false)

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(instance.configuration.startsAutomaticallyOnLaunch == true)
        reapply(vc, (instance, viewModel))
        let panelSwitch = try #require(
            firstSubview(NSSwitch.self, in: vc.view) {
                $0.action.map(NSStringFromSelector) == "autoStartToggled"
            })
        #expect(panelSwitch.state == .on)
    }

    @Test("Cancelling the passthrough confirmation puts the panel's switch back")
    func cancelledPassthroughRevertsEverySurface() throws {
        let (vc, instance, viewModel) = makeController()
        instance.configuration.clipboardSharingEnabled = true
        reapply(vc, (instance, viewModel))
        let panelToggle = try #require(
            firstSubview(NSSwitch.self, in: vc.view) {
                $0.action.map(NSStringFromSelector) == "clipboardPassthroughToggled"
            })

        // The user flipped the panel's switch; the confirmation sheet is up.
        panelToggle.state = .on
        vc.cancelPassthroughEnableForTesting()

        #expect(instance.configuration.clipboardPassthroughEnabled == false)
        #expect(panelToggle.state == .off)
        // The card reads the model, so its line never claimed otherwise.
        #expect(
            summaryLine(in: try card(.sharing, in: vc))
                == "Passthrough off \u{00B7} No shared folders")
    }

    @Test("The Sharing card states passthrough in its line, not as a switch")
    func sharingCardLineFollowsPassthrough() throws {
        let (vc, instance, viewModel) = makeController()
        let sharing = try card(.sharing, in: vc)
        #expect(cardSwitch(.clipboardPassthrough, in: sharing) == nil)
        #expect(summaryLine(in: sharing) == "Passthrough off \u{00B7} No shared folders")

        // Turned on where the toggle still lives — the panel, or the clipboard
        // window — and shared a folder with the guest.
        instance.configuration.clipboardSharingEnabled = true
        instance.configuration.clipboardPassthroughEnabled = true
        instance.configuration.sharedDirectories = [SharedDirectory(path: "/tmp/share")]
        reapply(vc, (instance, viewModel))

        #expect(summaryLine(in: sharing) == "Passthrough on \u{00B7} 1 shared folder")
    }

    // MARK: - Lock hints and warnings

    @Test("Card lock hints show for lockable categories only while read-only")
    func cardLockHintsTrackReadOnly() throws {
        let (readOnlyVC, instance, _) = makeController(isReadOnly: true)
        for category in VMSettingsCategory.allCases {
            // A card carrying live switches makes no lock claim, whatever its
            // panel holds — covered on its own in `cardWithLiveSwitchesMakesNoLockClaim`.
            let claimsLock =
                category.containsLockableRows
                && VMOverviewSummary.toggles(for: category, instance: instance).isEmpty
            let hints = settingsLockHints(in: try card(category, in: readOnlyVC))
            #expect(hints.allSatisfy { $0.isHidden != claimsLock })
        }

        let (editableVC, _, _) = makeController(isReadOnly: false)
        for category in VMSettingsCategory.allCases {
            #expect(settingsLockHints(in: try card(category, in: editableVC)).allSatisfy(\.isHidden))
        }
    }

    @Test("A card carrying live switches states no lock hint")
    func cardWithLiveSwitchesMakesNoLockClaim() throws {
        let (vc, _, _) = makeController(isReadOnly: true)

        // Sharing locks only its Shared Directories section, and its card offers
        // clipboard sharing and drag and drop as live switches — so the card
        // cannot claim the category is editable only when stopped.
        #expect(settingsLockHints(in: try card(.sharing, in: vc)).allSatisfy(\.isHidden))
        #expect(settingsLockHints(in: try card(.storage, in: vc)).allSatisfy { !$0.isHidden })
        // The panel's own Shared Directories hint still states the lock.
        let panel = try #require(vc.panelForTesting(.sharing))
        #expect(settingsLockHints(in: panel).contains { !$0.isHidden })
    }

    @Test("The pane grows past the column cap instead of pinning its host's width")
    func paneGrowsPastTheColumnCap() throws {
        let (vc, _, _) = makeController()
        let window = makeTestWindow(styleMask: [.titled, .resizable])
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1600, height: 900))
        vc.view.layoutSubtreeIfNeeded()

        // The column stays capped and centered, but the pane itself takes every
        // point offered — a column preference that pulled its container in
        // instead would freeze the window's width and the split-view divider.
        #expect(vc.view.frame.width == 1600)
        let scrollView = try #require(firstSubview(NSScrollView.self, in: vc.view))
        let form = try #require(scrollView.documentView?.subviews.first)
        #expect(form.frame.width == GroupedFormStyle.columnWidth)
    }

    @Test("The Network card drops its lock hint while the picker hot-swaps")
    func networkCardHintFollowsLiveSwitchability() throws {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: .linux, macAddress: "aa:bb:cc:dd:ee:ff")
        instance.status = .running
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: true)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()

        #expect(settingsLockHints(in: try card(.network, in: vc)).allSatisfy(\.isHidden))
        // Every other lockable category still states the lock.
        #expect(settingsLockHints(in: try card(.storage, in: vc)).allSatisfy { !$0.isHidden })
    }

    @Test("A duplicate MAC address raises the Network card's warning glyph")
    func duplicateMACRaisesTheCardWarning() throws {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: .linux, macAddress: "aa:bb:cc:dd:ee:ff")
        let other = makeInstance(guestOS: .linux, macAddress: "aa:bb:cc:dd:ee:ff")
        other.configuration.name = "Twin"
        viewModel.instances = [instance, other]
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()

        let glyph = try #require(
            firstSubview(NSImageView.self, in: try card(.network, in: vc)) {
                !$0.isHidden && $0.toolTip?.contains("Twin") == true
            })
        #expect(glyph.toolTip?.contains("MAC address") == true)
        // A VM alone on its address raises nothing.
        let (plainVC, _, _) = makeController(guestOS: .linux)
        let plainCard = try card(.network, in: plainVC)
        #expect(
            firstSubview(NSImageView.self, in: plainCard) {
                $0.toolTip?.contains("MAC address") == true
            } == nil)
    }
}
