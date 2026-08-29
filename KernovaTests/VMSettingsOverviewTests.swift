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

    private func actionButton(_ action: VMOverviewAction, in card: NSView) -> NSButton? {
        firstSubview(NSButton.self, in: card) { $0.identifier?.rawValue == action.rawValue }
    }

    private func copyButton(in card: NSView) -> CopyValueButton? {
        firstSubview(CopyValueButton.self, in: card)
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

    @Test("A macOS card set offers drag and drop")
    func macOSCardsCoverGuestOnlySwitches() throws {
        let (vc, _, _) = makeController(guestOS: .macOS)
        #expect(cardSwitch(.dropFiles, in: try card(.sharing, in: vc)) != nil)
    }

    @Test("A Linux card set drops the macOS-only switch and keeps the clipboard one")
    func linuxCardsDropMacOSOnlySwitches() throws {
        let (vc, _, _) = makeController(guestOS: .linux)
        let sharing = try card(.sharing, in: vc)

        #expect(cardSwitch(.dropFiles, in: sharing) == nil)
        #expect(cardSwitch(.clipboardSharing, in: sharing) != nil)
        #expect(summaryLine(in: sharing) != nil)
    }

    @Test("The cards pair off two to a row, in category order")
    func cardsLayOutTwoPerRow() throws {
        let (vc, _, _) = makeController()
        let window = makeTestWindow(styleMask: [.titled, .resizable])
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 900, height: 1200))
        vc.view.layoutSubtreeIfNeeded()

        let pairs: [(VMSettingsCategory, VMSettingsCategory)] = [
            (.general, .system), (.storage, .network), (.sharing, .snapshots),
        ]
        for (leading, trailing) in pairs {
            let left = try card(leading, in: vc)
            let right = try card(trailing, in: vc)
            let leftFrame = left.convert(left.bounds, to: vc.view)
            let rightFrame = right.convert(right.bounds, to: vc.view)
            #expect(rightFrame.minX > leftFrame.maxX)
            // Tops align on a row — the pane's views are unflipped, so that is
            // `maxY` — while the heights stay each card's own business.
            #expect(abs(rightFrame.maxY - leftFrame.maxY) < 1)
            #expect(abs(leftFrame.width - rightFrame.width) < 1)
        }
        // The pairs stack down the column rather than running on.
        let general = try card(.general, in: vc)
        let storage = try card(.storage, in: vc)
        #expect(
            storage.convert(storage.bounds, to: vc.view).maxY
                <= general.convert(general.bounds, to: vc.view).minY)
    }

    @Test("A card's drill-in reads Edit, in the accent color")
    func cardEditAffordanceIsAnAccentButton() throws {
        let (vc, _, _) = makeController()
        let edit = try #require(showButton(.system, in: try card(.system, in: vc)))
        #expect(edit.title == "Edit")
        #expect(!edit.isBordered)
        #expect(edit.contentTintColor == .controlAccentColor)
        #expect(edit.imagePosition == .imageTrailing)
        #expect(edit.accessibilityLabel() == "Show System")
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

    @Test("A card's lock glyph shows only while read-only, and only where rows lock")
    func cardLockGlyphsTrackReadOnly() throws {
        let (readOnlyVC, _, _) = makeController(isReadOnly: true)
        for category in VMSettingsCategory.allCases {
            let card = try self.card(category, in: readOnlyVC)
            guard let hint = category.lockHint else {
                // Nothing in General or Snapshots is stopped-only, so neither
                // card claims a lock at all.
                #expect(firstSubview(NSImageView.self, in: card) { $0.toolTip != nil } == nil)
                continue
            }
            let glyph = try #require(cardLockGlyph(category, in: card))
            #expect(!glyph.isHidden)
            #expect(glyph.toolTip == hint)
            // Glyph only: a two-column card has no room for the hint's text.
            #expect(findLabel(withText: hint, in: card) == nil)
            #expect(findLabel(withText: groupedFormLockHintText, in: card) == nil)
        }

        let (editableVC, _, _) = makeController(isReadOnly: false)
        for category in VMSettingsCategory.allCases {
            let card = try self.card(category, in: editableVC)
            #expect(cardLockGlyph(category, in: card)?.isHidden != false)
        }
    }

    @Test("The scoped claim stands beside a card's live switches")
    func scopedLockClaimStandsBesideLiveSwitches() throws {
        let (vc, _, _) = makeController(isReadOnly: true)
        let sharing = try card(.sharing, in: vc)

        // Every switch on the Sharing card edits live; the glyph claims only
        // that the folders lock, so it contradicts nothing beside it.
        #expect(cardSwitch(.clipboardSharing, in: sharing) != nil)
        let glyph = try #require(cardLockGlyph(.sharing, in: sharing))
        #expect(!glyph.isHidden)
        #expect(glyph.toolTip == "Folders editable when stopped")
        // The panel's own Shared Directories hint still states the full text.
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

    @Test("The Network card keeps its claim while the picker hot-swaps")
    func networkCardClaimSurvivesLiveSwitching() throws {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: .linux, macAddress: "aa:bb:cc:dd:ee:ff")
        instance.status = .running
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: true)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()

        // The mode picker live-switches on a running VM, but the MAC address and
        // the forwarding rules still lock — which is all the claim says.
        let glyph = try #require(cardLockGlyph(.network, in: try card(.network, in: vc)))
        #expect(!glyph.isHidden)
        #expect(glyph.toolTip == "Most editable when stopped")
    }

    // MARK: - Card contents

    @Test("The Network card folds the address into the mode row, with a copy button")
    func networkCardCopiesTheAddress() throws {
        let (vc, _, _) = makeController(guestOS: .linux)
        let network = try card(.network, in: vc)
        // A stopped VM has no address yet, so nothing offers to copy one.
        #expect(copyButton(in: network) == nil)

        let panel = try #require(vc.settingsPanelForTesting(.network))
        var resolved = VMOverviewResolved()
        panel.contribute(to: &resolved)
        let mode = try #require(resolved.networkModeTitle)
        #expect(findLabel(withText: mode, in: network) != nil)
    }

    @Test("The Storage card names the boot disk and folds the rest into one line")
    func storageCardStatesBootDiskAndTheRest() throws {
        let (vc, instance, _) = makeController()
        let storage = try card(.storage, in: vc)
        #expect(findLabel(withText: "Boot disk", in: storage) != nil)
        #expect(findLabel(withText: instance.displayedStorageDisks[0].label, in: storage) != nil)
        #expect(findLabel(withText: "No other disks · No media", in: storage) != nil)
        // Cores, memory and the disk figure belong to the header's facts line.
        #expect(findLabel(withText: "CPU cores", in: try card(.system, in: vc)) == nil)
        #expect(findLabel(withText: "Memory", in: try card(.system, in: vc)) == nil)
    }

    @Test("The General card is its two switches and nothing else")
    func generalCardIsSwitchesOnly() throws {
        let (vc, _, _) = makeController()
        let general = try card(.general, in: vc)
        #expect(cardSwitch(.autoStart, in: general) != nil)
        #expect(cardSwitch(.ephemeralMode, in: general) != nil)
        for label in ["Type", "Boot mode", "Created"] {
            #expect(findLabel(withText: label, in: general) == nil)
        }
    }

    @Test("The Snapshots card counts them in its header and offers the capture at its foot")
    func snapshotCardHeaderAndCaptureCommand() throws {
        let (vc, instance, viewModel) = makeController()
        let snapshots = try card(.snapshots, in: vc)
        let presenter = MockVMLibraryPresenting()
        viewModel.presenter = presenter

        // Nothing captured yet: no count beside the title, and no count row.
        #expect(findLabel(withText: "Snapshots", in: snapshots) != nil)
        #expect(findLabel(withText: "Latest", in: snapshots) == nil)

        let snapshot = VMSnapshot(name: "Base")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [snapshot], currentID: snapshot.id)
        reapply(vc, (instance, viewModel))

        // The count sits beside the title, the footprint joining it once the
        // panel's off-main size read lands.
        #expect(
            firstSubview(NSTextField.self, in: snapshots) {
                $0.stringValue == "1" || $0.stringValue.hasPrefix("1 \u{00B7} ")
            } != nil)
        #expect(findLabel(withText: "Latest", in: snapshots) != nil)

        // A stopped VM can be captured, and the card runs the same view-model
        // gate the panel's own button runs.
        let take = try #require(actionButton(.takeSnapshot, in: snapshots))
        #expect(take.title == "Take Snapshot\u{2026}")
        #expect(take.contentTintColor == .controlAccentColor)
        #expect(take.isEnabled)
        take.performClick(nil)
        #expect(presenter.takeSnapshotSheetInstances.map(\.id) == [instance.id])
    }

    @Test("A long network mode gives up its width before the address beside it")
    func longModeTitleYieldsToTheAddress() throws {
        // A bridged mode carries a host interface's name, which is unbounded —
        // and a half-width card leaves the row around 278 points.
        let mode = "Thunderbolt Bridge (bridge0)"
        let card = VMOverviewCardView(category: .network, toggles: [])
        card.configure(
            rows: [
                VMOverviewSummary.Row(
                    label: mode, value: "192.168.66.4",
                    copy: VMOverviewSummary.RowCopy(
                        value: "192.168.66.4", name: "Copy IP Address"))
            ],
            toggles: [], note: nil, action: nil, headerSummary: nil, showsLockHint: false,
            warning: nil)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 302, height: 200))
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = host
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let value = try #require(
            firstSubview(NSTextField.self, in: card) { $0.stringValue == "192.168.66.4" })
        let copy = try #require(copyButton(in: card))
        let label = try #require(firstSubview(NSTextField.self, in: card) { $0.toolTip == mode })
        // The address and its copy button stay whole; the mode truncates, and
        // keeps the whole of itself in the tooltip.
        #expect(value.frame.width >= value.intrinsicContentSize.width - 1)
        #expect(copy.frame.width >= copy.intrinsicContentSize.width - 1)
        #expect(copy.frame.width > 0)
        #expect(label.frame.width < label.intrinsicContentSize.width)
        #expect(label.lineBreakMode == .byTruncatingTail)
    }

    @Test("The snapshots' footprint is dropped with the set it described")
    func snapshotFootprintNeverOutlivesItsSnapshots() async throws {
        let (vc, instance, viewModel) = makeController()
        let first = VMSnapshot(name: "First")
        let second = VMSnapshot(name: "Second")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [first, second], currentID: second.id)
        reapply(vc, (instance, viewModel))

        let panel = try #require(
            vc.settingsPanelForTesting(.snapshots) as? VMSettingsSnapshotsPanelViewController)
        func contributedTotal() -> UInt64? {
            var resolved = VMOverviewResolved()
            panel.contribute(to: &resolved)
            return resolved.snapshotTotalBytes
        }
        await panel.snapshotSizeTaskForTesting?.value
        #expect(contributedTotal() != nil)

        // Dropping a snapshot leaves the stored total describing a set that no
        // longer exists, so the card falls back to the count alone.
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [first], currentID: first.id)
        reapply(vc, (instance, viewModel))
        #expect(contributedTotal() == nil)

        await panel.snapshotSizeTaskForTesting?.value
        #expect(contributedTotal() != nil)

        // Same for a switch to another VM: its count must not land beside the
        // previous VM's footprint.
        let other = makeInstance(guestOS: .macOS)
        let onlySnapshot = VMSnapshot(name: "Other")
        other.snapshotManifest = VMSnapshotManifest(
            snapshots: [onlySnapshot], currentID: onlySnapshot.id)
        vc.reconfigure(instance: other, viewModel: viewModel, isReadOnly: false)
        #expect(contributedTotal() == nil)
        #expect(
            VMOverviewSummary.headerSummary(
                for: .snapshots, instance: other, resolved: VMOverviewResolved()) == "1")
    }

    @Test("The capture command dims when the VM is in no state to be captured")
    func takeSnapshotFollowsTheViewModelGate() throws {
        let (vc, instance, viewModel) = makeController()
        instance.status = .starting
        reapply(vc, (instance, viewModel))

        let take = try #require(actionButton(.takeSnapshot, in: try card(.snapshots, in: vc)))
        #expect(!take.isEnabled)
        #expect(!viewModel.canTakeSnapshot(instance))
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
