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

    /// The tile's back button, which carries a glyph and no title.
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

    @Test("The cards stack one per row, at the column's full width, in category order")
    func cardsStackInOneColumn() throws {
        let (vc, _, _) = makeController()
        let window = makeTestWindow(styleMask: [.titled, .resizable])
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 900, height: 1600))
        vc.view.layoutSubtreeIfNeeded()

        var previous: NSRect?
        for category in VMSettingsCategory.allCases {
            let card = try self.card(category, in: vc)
            let frame = card.convert(card.bounds, to: vc.view)
            #expect(frame.width == GroupedFormStyle.columnWidth)
            if let previous {
                // The pane's views are unflipped, so each card sits below the
                // one before it — no two share a row.
                #expect(frame.maxY <= previous.minY)
                #expect(abs(frame.minX - previous.minX) < 1)
            }
            previous = frame
        }
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
        // The overview builds no panel, so there is nothing of Storage's in the
        // form until the drill-in.
        #expect(vc.panelForTesting(.storage) == nil)
        #expect(isVisible(storageCard, within: vc.view))

        let show = try #require(showButton(.storage, in: storageCard))
        show.performClick(nil)

        #expect(vc.selectedCategory == .storage)
        let panel = try #require(vc.panelForTesting(.storage))
        #expect(isVisible(panel, within: vc.view))
        #expect(!isVisible(storageCard, within: vc.view))

        let header = try #require(firstSubview(VMIdentityHeaderView.self, in: vc.view))
        try #require(backButton(in: header)).performClick(nil)

        #expect(vc.selectedCategory == nil)
        #expect(isVisible(storageCard, within: vc.view))
        // The panel's view leaves the form entirely; its controller — and
        // everything it resolved — stays for the next drill-in.
        #expect(panel.superview == nil)
        #expect(vc.settingsPanelForTesting(.storage) != nil)
    }

    @Test("A panel is built once per VM: re-opening reuses it, a VM switch rebuilds it")
    func panelsAreBuiltOnceUntilTheVMMoves() throws {
        let (vc, _, viewModel) = makeController()
        /// A section built by the last `rebuild()`, which a rebuild replaces.
        func firstSection() throws -> NSView {
            try #require(vc.panelForTesting(.system)?.subviews.first)
        }

        vc.showCategory(.system)
        let built = try firstSection()
        vc.showOverview()
        vc.showCategory(.system)
        #expect(try firstSection() === built)

        vc.showOverview()
        vc.reconfigure(
            instance: makeInstance(guestOS: .macOS), viewModel: viewModel, isReadOnly: false)
        vc.showCategory(.system)
        // The VM under it moved, so the drill-in rebuilt the panel for the new
        // one rather than showing the previous VM's rows.
        #expect(try firstSection() !== built)
        #expect(findLabel(withText: "CPU cores", in: try firstSection()) != nil)
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
            #expect(vc.panelForTesting(category) == nil)
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

    @Test("Drilling in morphs the one header anatomy rather than swapping another in")
    func panelHeaderMorphsTheTileInPlace() throws {
        let (vc, instance, _) = makeController()
        let window = makeTestWindow(styleMask: [.titled])
        window.setContentSize(NSSize(width: 700, height: 400))
        window.contentView = vc.view
        let header = try #require(firstSubview(VMIdentityHeaderView.self, in: vc.view))
        vc.view.layoutSubtreeIfNeeded()
        let facts = header.renderedFactsLine
        #expect(!facts.isEmpty)
        // The overview states the VM's name over the facts line, on its tile.
        #expect(findLabel(withText: instance.name, in: header) != nil)
        let tile = try #require(firstSubview(NSBox.self, in: header))
        #expect(isVisible(tile, within: header))
        #expect(backButton(in: header)?.isHidden == true)

        vc.showCategory(.system)
        vc.view.layoutSubtreeIfNeeded()

        // The same header, reconfigured — not a second view swapped in.
        #expect(firstSubview(VMIdentityHeaderView.self, in: vc.view) === header)
        let back = try #require(backButton(in: header))
        let title = try #require(findLabel(withText: "System", in: header))
        let factsLabel = try #require(findLabel(withText: facts, in: header))
        #expect(back.accessibilityLabel() == "Back")
        // The tile stays; only the glyph it carries changes, in the accent color
        // the cards' Edit affordances use.
        #expect(isVisible(tile, within: header))
        #expect(!back.isHidden)
        #expect(!back.isBordered)
        #expect(back.contentTintColor == .controlAccentColor)
        #expect(findLabel(withText: instance.name, in: header) == nil)
        #expect(title.font == Typography.title)
        let tileFrame = tile.convert(tile.bounds, to: header)
        let backFrame = back.convert(back.bounds, to: header)
        let titleFrame = title.convert(title.bounds, to: header)
        let factsFrame = factsLabel.convert(factsLabel.bounds, to: header)
        // The glyph sits on the tile, the title beside it, the facts below.
        #expect(abs(backFrame.midX - tileFrame.midX) < 1)
        #expect(titleFrame.minX > tileFrame.maxX)
        #expect(factsFrame.maxY <= titleFrame.minY)
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
        vc.showCategory(.general)
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
        vc.showCategory(.sharing)
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
        vc.showOverview()
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

    @Test("A card's lock hint shows only while read-only, and only where rows lock")
    func cardLockHintsTrackReadOnly() throws {
        let (readOnlyVC, _, _) = makeController(isReadOnly: true)
        for category in VMSettingsCategory.allCases {
            let card = try self.card(category, in: readOnlyVC)
            guard let claim = category.lockHint else {
                // Nothing in General or Snapshots is stopped-only, so neither
                // card claims a lock at all.
                #expect(findLabel(containing: "editable when stopped", in: card) == nil)
                continue
            }
            let hint = try #require(cardLockHint(category, in: card))
            #expect(!hint.isHidden)
            #expect(hint.toolTip == claim)
            // The scoped claim reads inline, not only in the tooltip.
            #expect(findLabel(withText: claim, in: card) != nil)
            // Never the panels' unscoped text, which a card's live controls
            // would contradict.
            #expect(findLabel(withText: groupedFormLockHintText, in: card) == nil)
        }

        let (editableVC, _, _) = makeController(isReadOnly: false)
        for category in VMSettingsCategory.allCases {
            let card = try self.card(category, in: editableVC)
            #expect(cardLockHint(category, in: card)?.isHidden != false)
        }
    }

    @Test("The scoped claim stands beside a card's live switches")
    func scopedLockClaimStandsBesideLiveSwitches() throws {
        let (vc, _, _) = makeController(isReadOnly: true)
        let sharing = try card(.sharing, in: vc)

        // Every switch on the Sharing card edits live; the hint claims only
        // that the folders lock, so it contradicts nothing beside it.
        #expect(cardSwitch(.clipboardSharing, in: sharing) != nil)
        let hint = try #require(cardLockHint(.sharing, in: sharing))
        #expect(!hint.isHidden)
        #expect(hint.toolTip == "Folders editable when stopped")
        #expect(findLabel(withText: "Folders editable when stopped", in: sharing) != nil)
        // The panel's own Shared Directories hint still states the full text.
        vc.showCategory(.sharing)
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
        instance.enter(.running(sessionID: UUID()))
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: true)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()

        // The mode picker live-switches on a running VM, but the MAC address and
        // the forwarding rules still lock — which is all the claim says.
        let hint = try #require(cardLockHint(.network, in: try card(.network, in: vc)))
        #expect(!hint.isHidden)
        #expect(hint.toolTip == "Most editable when stopped")
    }

    // MARK: - Card contents

    @Test("The Network card folds the address into the mode row, with a copy button")
    func networkCardCopiesTheAddress() throws {
        let (vc, _, _) = makeController(guestOS: .linux)
        let network = try card(.network, in: vc)
        // A stopped VM has no address yet, so nothing offers to copy one.
        #expect(copyButton(in: network) == nil)

        let mode = try #require(vc.resolvedForTesting.networkModeTitle)
        #expect(findLabel(withText: mode, in: network) != nil)
    }

    @Test("The Storage card names the boot disk and folds the rest into one line")
    func storageCardStatesBootDiskAndTheRest() throws {
        let (vc, instance, _) = makeController()
        let storage = try card(.storage, in: vc)
        #expect(findLabel(withText: "Boot disk", in: storage) != nil)
        #expect(findLabel(withText: instance.effectiveStorageDisks[0].label, in: storage) != nil)
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
        // A bridged mode carries a host interface's name, which is unbounded,
        // and the pane fills a container narrower than the column cap.
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

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
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

    @Test("The snapshots' footprint is never claimed for a set it doesn't cover")
    func snapshotFootprintNeverOutlivesItsSnapshots() async throws {
        let (vc, instance, viewModel) = makeController()
        let first = VMSnapshot(name: "First")
        let second = VMSnapshot(name: "Second")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [first, second], currentID: second.id)
        reapply(vc, (instance, viewModel))

        let resolver = vc.overviewResolverForTesting
        await resolver.snapshotSizeTaskForTesting?.value
        #expect(resolver.resolved.snapshotTotalBytes != nil)

        // Capturing another leaves the set part-measured, so the card states the
        // count alone until the fresh read covers the newcomer too.
        let third = VMSnapshot(name: "Third")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [first, second, third], currentID: third.id)
        reapply(vc, (instance, viewModel))
        #expect(resolver.resolved.snapshotTotalBytes == nil)

        await resolver.snapshotSizeTaskForTesting?.value
        #expect(resolver.resolved.snapshotTotalBytes != nil)

        // A switch to another VM drops the footprint outright: its count must
        // not land beside the previous VM's.
        let other = makeInstance(guestOS: .macOS)
        let onlySnapshot = VMSnapshot(name: "Other")
        other.snapshotManifest = VMSnapshotManifest(
            snapshots: [onlySnapshot], currentID: onlySnapshot.id)
        vc.reconfigure(instance: other, viewModel: viewModel, isReadOnly: false)
        #expect(resolver.resolved.snapshotTotalBytes == nil)
        #expect(
            VMOverviewSummary.headerSummary(
                for: .snapshots, instance: other, resolved: VMOverviewResolved()) == "1")
    }

    @Test("The capture command dims when the VM is in no state to be captured")
    func takeSnapshotFollowsTheViewModelGate() throws {
        let (vc, instance, viewModel) = makeController()
        instance.enter(.starting(sessionID: nil))
        reapply(vc, (instance, viewModel))

        let take = try #require(actionButton(.takeSnapshot, in: try card(.snapshots, in: vc)))
        #expect(!take.isEnabled)
        #expect(!viewModel.capabilities.isAvailable(.takeSnapshot, on: instance))
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
