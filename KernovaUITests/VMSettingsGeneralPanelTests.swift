import AVFoundation
import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// The General panel's own behavior, drilled into through the shell.
@Suite("VM Settings General Panel Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMSettingsGeneralPanelTests {
    private let preferences = makeTestPreferences()

    private func makeViewModel() -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences)
    }

    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = .general
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        makeSettingsController(
            guestOS: guestOS, isReadOnly: isReadOnly, category: category,
            preferences: preferences)
    }

    // MARK: - Rename session across a rebind

    @Test("A read-only flip on the same VM leaves an open rename alone")
    func readOnlyFlipDoesNotCommitAnOpenRename() throws {
        let (vc, instance, viewModel) = makeController(
            guestOS: .linux, isReadOnly: false, category: .general)
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        viewModel.renameVMInDetail(instance)
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)
        // The panel's only editable field is the name box the rename opened.
        let panel = try #require(vc.panelForTesting(.general))
        let field = try #require(findEditableField(in: panel))
        field.currentEditor()?.string = "Half-typed"
        field.stringValue = "Half-typed"

        // The VM starting flips the pane read-only, which re-enters
        // `reconfigure` with the same instance — not an outgoing one, so the
        // half-typed name must not commit.
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: true)

        #expect(instance.name == "Test VM")
        #expect(viewModel.activeRename == .detail(instance.id))
    }

    /// The handoff the two rename surfaces share: the sidebar taking the rename
    /// supersedes this one, and the text typed here has to reach the model
    /// rather than being dropped with the box.
    @Test("A superseded detail rename still commits what was typed into it")
    func supersededDetailRenameCommitsItsText() throws {
        let (vc, instance, viewModel) = makeController(
            guestOS: .linux, isReadOnly: false, category: .general)
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        viewModel.renameVMInDetail(instance)
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)
        let panel = try #require(vc.panelForTesting(.general))
        let field = try #require(findEditableField(in: panel))
        field.currentEditor()?.string = "Typed in detail"
        field.stringValue = "Typed in detail"

        // The sidebar takes the rename over, which is what the pane sees.
        viewModel.renameVMInSidebar(instance)
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)

        #expect(instance.name == "Typed in detail")
        // The marker belongs to the sidebar now, and the detail commit left it.
        #expect(viewModel.activeRename == .sidebar(instance.id))
    }

    /// The row used to be a borderless button, which grayed its own title; a
    /// plain label doesn't, so the pane has to gray it.
    @Test("The name reads as disabled while the VM can't be renamed")
    func nameGraysWhenRenameIsUnavailable() throws {
        let viewModel = makeViewModel()
        // A revert refuses the rename it would assign back over.
        let instance = makeSettingsInstance(
            guestOS: .linux,
            phase: .operating(
                .bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped))
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: true)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)

        #expect(!viewModel.capabilities.isAvailable(.rename, on: instance))
        let panel = try #require(vc.panelForTesting(.general))
        let name = try #require(
            firstSubview(InlineEditableLabel.self, in: panel) { $0.stringValue == instance.name })
        #expect(name.textColor == .disabledControlTextColor)
    }

    // MARK: - General card OS rows

    private func makeOSRowsController(
        guestOS: VMGuestOS,
        installedImage: InstalledImage? = nil,
        lastSeenGuestOSVersion: String? = nil
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        let viewModel = makeViewModel()
        let instance = makeSettingsInstance(guestOS: guestOS) {
            $0.installedImage = installedImage
            $0.lastSeenGuestOSVersion = lastSeenGuestOSVersion
        }
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)
        return (vc, instance, viewModel)
    }

    /// The install record standing alone reads as the version the guest runs
    /// today, which it stops being at the first in-guest update.
    @Test("A macOS VM no agent has reported on says its OS version is unknown beside the install record")
    func osRowsInstallRecordOnly() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .macOS,
            installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"))

        #expect(visibleLabel("Installed from", in: vc.view))
        #expect(visibleLabel("OS version", in: vc.view))
        #expect(visibleLabel(VMSettingsGeneralPanelViewController.unknownGuestOSVersion, in: vc.view))
    }

    @Test("A Linux VM names the attached media beside its unknown OS version")
    func osRowsLinuxCatalogImage() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .linux,
            installedImage: .linuxCatalogImage(
                distribution: "Ubuntu Desktop", version: "26.04 LTS", digest: nil))

        #expect(visibleLabel("Installer image", in: vc.view))
        #expect(visibleLabel("Ubuntu Desktop 26.04 LTS", in: vc.view))
        // Booting that ISO is not installing from it — the guest's own
        // installer can write another distribution, or nothing at all — so the
        // row must never claim the install happened.
        #expect(!containsLabel("Installed from", in: vc.view))
        #expect(visibleLabel("OS version", in: vc.view))
        #expect(visibleLabel(VMSettingsGeneralPanelViewController.unknownGuestOSVersion, in: vc.view))
    }

    // MARK: - Installer image digest

    private static let sha256 =
        "0123456789abcdef" + String(repeating: "5", count: 32) + "fedcba9876543210"
    private static let checksumListURL = URL(
        string: "https://cdimage.ubuntu.com/releases/26.04/SHA256SUMS")!
    private static let isoURL = URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!

    private static func matched(_ source: DigestSource, filename: String) -> InstallerImageDigest? {
        ExpectedDigest(sha256: sha256, source: source).match(sha256, filename: filename)
    }

    /// The General panel's label reading exactly `text`, visible or not.
    private func panelLabel(_ text: String, in vc: VMSettingsViewController) -> NSTextField? {
        vc.panelForTesting(.general).flatMap { findLabel(withText: text, in: $0) }
    }

    @Test("A catalog image checked against its checksum list shows the digest and where it matched")
    func digestRowsForChecksumList() throws {
        let digest = try #require(
            Self.matched(.checksumList(Self.checksumListURL), filename: "ubuntu-26.04-desktop-arm64.iso"))
        let (vc, _, _) = makeOSRowsController(
            guestOS: .linux,
            installedImage: .linuxCatalogImage(
                distribution: "Ubuntu Desktop", version: "26.04 LTS", digest: digest))

        #expect(panelLabel("Ubuntu Desktop 26.04 LTS", in: vc)?.toolTip == "ubuntu-26.04-desktop-arm64.iso")
        #expect(visibleLabel("SHA-256", in: vc.view))
        let value = try #require(panelLabel("01234567\u{2026}76543210", in: vc))
        #expect(isVisible(value, within: vc.view))
        #expect(value.toolTip == Self.sha256)
        #expect(value.font?.isFixedPitch == true)
        let copy = try #require(
            vc.panelForTesting(.general).flatMap { firstSubview(CopyValueButton.self, in: $0) })
        #expect(copy.value == Self.sha256)
        #expect(!copy.isHidden)
        #expect(visibleLabel("Verification", in: vc.view))
        let verification = try #require(
            panelLabel("Matched the checksum list on cdimage.ubuntu.com", in: vc))
        #expect(isVisible(verification, within: vc.view))
        #expect(verification.toolTip == Self.checksumListURL.absoluteString)
    }

    /// The General card's visible run of rows and hairlines, `true` for a
    /// hairline — collapsible rows expanded, hidden views dropped.
    ///
    /// Scoped to the General panel: the overview's General card states some of
    /// the same rows and would match first.
    private func generalCardLayout(in vc: VMSettingsViewController) -> [Bool] {
        // The card's content stack is the one holding separators directly, which
        // no section or form stack does.
        guard let panel = vc.panelForTesting(.general) else {
            Issue.record("Expected a General panel")
            return []
        }
        guard
            let content = firstSubview(
                NSStackView.self, in: panel,
                where: { stack in
                    stack.arrangedSubviews.contains { $0 is GroupedFormCardSeparator }
                        && findLabel(withText: "Boot mode", in: stack) != nil
                })
        else {
            Issue.record("Expected a General card content stack")
            return []
        }
        return content.arrangedSubviews.filter { !$0.isHidden }.flatMap { view -> [Bool] in
            guard let collapsible = view as? GroupedFormCollapsibleRow else {
                return [view is GroupedFormCardSeparator]
            }
            return collapsible.arrangedSubviews.filter { !$0.isHidden }.map { $0 is GroupedFormCardSeparator }
        }
    }

    /// Whether a card's rows and hairlines strictly alternate, starting and
    /// ending on a row — the shape a hidden row must not disturb.
    private func separatesEveryRow(_ layout: [Bool]) -> Bool {
        layout.first == false && layout.last == false
            && zip(layout, layout.dropFirst()).allSatisfy { $0 != $1 }
    }

    // MARK: - Launch auto-start

    @Test("Toggling the Startup switch writes back to the configuration")
    func autoStartToggleWritesConfig() {
        let (vc, instance, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(instance.hostState.startsAutomaticallyOnLaunch == false)

        guard let autoStart = firstSwitch(action: "autoStartToggled", in: vc.view) else {
            Issue.record("Expected a Startup switch")
            return
        }
        autoStart.state = .on
        autoStart.sendAction(autoStart.action, to: autoStart.target)

        #expect(instance.hostState.startsAutomaticallyOnLaunch == true)
    }

    // MARK: - Ephemeral Mode

    /// Builds a settings pane over a VM carrying `snapshotCount` snapshots of
    /// `kind`, the oldest of which is the Current one.
    private func makeEphemeralController(
        snapshotCount: Int, ephemeral: Bool, isReadOnly: Bool = false,
        kind: VMSnapshotKind = .warm
    ) -> (VMSettingsViewController, VMInstance) {
        makeEphemeralController(
            snapshots: (0..<snapshotCount).map { makeSnapshot(index: $0, kind: kind) },
            ephemeral: ephemeral, isReadOnly: isReadOnly)
    }

    /// One snapshot of the series the count-based helper builds: named for its
    /// index, and a minute newer than the one before it.
    private func makeSnapshot(
        index: Int, kind: VMSnapshotKind, name: String? = nil
    ) -> VMSnapshot {
        VMSnapshot(
            name: name ?? "Snapshot \(index)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
            kind: kind, macAddress: nil)
    }

    /// Builds a settings pane over a VM carrying `snapshots`, the first of which
    /// is the Current one and, in the mode, the baseline.
    private func makeEphemeralController(
        snapshots: [VMSnapshot], ephemeral: Bool, isReadOnly: Bool = false,
        viewModel: VMLibraryViewModel? = nil
    ) -> (VMSettingsViewController, VMInstance) {
        let viewModel = viewModel ?? makeViewModel()
        let baseline = ephemeral ? snapshots.first : nil
        let instance = viewModel.library.registerFixture(
            guestOS: .linux,
            hostState: baseline.map { .ephemeral(baseline: $0.id) } ?? VMHostState())
        instance.seedSnapshotManifest(
            VMSnapshotManifest(
                snapshots: snapshots, currentID: snapshots.first?.id))
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)
        return (vc, instance)
    }

    /// The baseline capture follows Take Snapshot's own availability, so a VM
    /// that can't be snapshotted has a dimmed switch rather than one opening a
    /// sheet that can't confirm.
    @Test("With Take Snapshot unavailable and no snapshot, the toggle is dimmed")
    func ephemeralToggleDimsWhenTheCaptureIsUnavailable() throws {
        let viewModel = makeViewModel()
        let (vc, instance) = makeEphemeralController(
            snapshots: [], ephemeral: false, viewModel: viewModel)
        instance.activity.placeForTesting(.initialBoot)
        try #require(!viewModel.capabilities.isAvailable(.takeSnapshot, on: instance))
        vc.viewDidAppear()

        let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view)
        #expect(toggle?.isEnabled == false)
        #expect(toggle?.alphaValue ?? 1 < 1)
        #expect(visibleLabel(EphemeralModeCopy.noSnapshotsCaption(capturesBaseline: false), in: vc.view))
    }

    /// The mode turns on only once the capture lands, so the switch reads off
    /// while the sheet is up and nothing is written.
    @Test("Turning the mode on with no snapshot opens the baseline sheet and writes nothing")
    func ephemeralEnableWithoutSnapshotsOpensTheSheet() throws {
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeViewModel()
        viewModel.presenter = presenter
        let storage = try #require(viewModel.storageService as? MockVMStorageService)
        let (vc, instance) = makeEphemeralController(
            snapshots: [], ephemeral: false, viewModel: viewModel)
        let hostStateOnDisk = storage.hostStates[instance.bundleURL]
        let toggle = try #require(firstSwitch(action: "ephemeralModeToggled", in: vc.view))

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(presenter.takeSnapshotSheetInstances.map(\.id) == [instance.id])
        #expect(presenter.takeSnapshotSheetPurposes == [.ephemeralBaseline])
        #expect(presenter.errors.isEmpty)
        #expect(!instance.hostState.ephemeralModeEnabled)
        #expect(storage.hostStates[instance.bundleURL] == hostStateOnDisk)
        #expect(toggle.state == .off)
    }

    @Test("The Ephemeral offer and the no-snapshot caption are the catalog's answer")
    func ephemeralOfferIsTheCatalogsAnswer() throws {
        let key = VMConfigurationKeyRegistry.ephemeral
        for hasSnapshots in [false, true] {
            for ephemeral in [false, true] {
                // A VM can only have entered the mode with a snapshot; one with
                // none has since lost its manifest.
                let viewModel = makeViewModel()
                let (vc, instance) = makeEphemeralController(
                    snapshots: (0..<(hasSnapshots || ephemeral ? 2 : 0)).map {
                        makeSnapshot(index: $0, kind: .warm)
                    },
                    ephemeral: ephemeral, viewModel: viewModel)
                if !hasSnapshots && ephemeral {
                    instance.seedSnapshotManifest(VMSnapshotManifest())
                    vc.viewDidAppear()
                }
                let label = "snapshots=\(hasSnapshots) ephemeral=\(ephemeral)"
                let toggle = try #require(firstSwitch(action: "ephemeralModeToggled", in: vc.view))
                let enable = viewModel.capabilities.ephemeralModeEnable(on: instance)

                #expect(
                    toggle.isEnabled
                        == (ephemeral
                            ? key.accepts("false", for: instance, in: viewModel.library)
                            : viewModel.capabilities.isEphemeralModeEnableAvailable(on: instance)),
                    "\(label)")
                #expect(
                    visibleLabel(
                        EphemeralModeCopy.noSnapshotsCaption(
                            capturesBaseline: enable == .capturingBaseline),
                        in: vc.view) == !hasSnapshots, "\(label)")
            }
        }
    }

    @Test("Turning the mode on asks first, and confirmed defaults the baseline to the current snapshot")
    func ephemeralToggleDefaultsToCurrent() throws {
        let viewModel = makeViewModel()
        let (vc, instance) = makeEphemeralController(
            snapshots: (0..<2).map { makeSnapshot(index: $0, kind: .warm) }, ephemeral: false,
            viewModel: viewModel)
        let window = showTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let toggle = try #require(firstSwitch(action: "ephemeralModeToggled", in: vc.view))

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        // The verb refused for want of consent, so nothing landed; the sheet
        // asks in the words that refusal carried.
        #expect(!instance.hostState.ephemeralModeEnabled)
        let current = try #require(instance.snapshotManifest.snapshots.first)
        let prompt = VMCommandCore.ephemeralBaselinePrompt(current, on: instance, turningOn: true)
        let sheet = try #require(window.attachedSheet)
        #expect(findLabel(withText: prompt.title, in: try #require(sheet.contentView)) != nil)

        // The confirmation's write.
        ConsentedSettingWrite(instance: instance, viewModel: viewModel, refresh: {}).write(
            VMConfigurationKeyRegistry.ephemeral.assigning(true), confirmingIn: nil,
            consent: Consent([.setEphemeralBaseline]))

        #expect(instance.hostState.ephemeralModeEnabled)
        #expect(
            instance.hostState.ephemeralBaselineSnapshotID
                == instance.snapshotManifest.currentID)
    }

    @Test("The toggle cautions what turning it on does while it would pin a baseline")
    func ephemeralToggleCautions() {
        let (off, offInstance) = makeEphemeralController(snapshotCount: 1, ephemeral: false)
        let baseline = offInstance.snapshotManifest.snapshots[0]
        #expect(visibleLabel(EphemeralModeCopy.enableCaution(baseline: baseline), in: off.view))

        let (on, onInstance) = makeEphemeralController(snapshotCount: 1, ephemeral: true)
        let pinned = onInstance.snapshotManifest.snapshots[0]
        #expect(!visibleLabel(EphemeralModeCopy.enableCaution(baseline: pinned), in: on.view))
    }

    @Test("Choosing another snapshot asks first, and confirmed moves the baseline")
    func ephemeralBaselineSelectionWritesConfig() throws {
        let viewModel = makeViewModel()
        let (vc, instance) = makeEphemeralController(
            snapshots: (0..<3).map { makeSnapshot(index: $0, kind: .warm) }, ephemeral: true,
            viewModel: viewModel)
        let window = showTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let popUp = try #require(firstPopUp(action: "ephemeralBaselineChanged", in: vc.view))
        // Rows render newest first, so the first item is not the Current one.
        let newest = try #require(popUp.itemArray[0].representedObject as? UUID)
        let pinned = instance.hostState.ephemeralBaselineSnapshotID

        popUp.select(popUp.itemArray[0])
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.hostState.ephemeralBaselineSnapshotID == pinned)
        #expect(window.attachedSheet != nil)

        // The confirmation's write.
        ConsentedSettingWrite(instance: instance, viewModel: viewModel, refresh: {}).write(
            VMConfigurationKeyRegistry.ephemeralBaseline.assigning(newest.uuidString),
            confirmingIn: nil, consent: Consent([.setEphemeralBaseline]))

        #expect(instance.hostState.ephemeralBaselineSnapshotID == newest)
        #expect(instance.hostState.ephemeralModeEnabled)
    }

    /// Nothing keeps two snapshots from sharing a name, and both have to stay
    /// pickable — an entry dropped for carrying a duplicate title would take a
    /// baseline out of reach.
    @Test("Two snapshots sharing a name both list")
    func ephemeralBaselineMenuKeepsDuplicateNames() throws {
        let snapshots = [
            makeSnapshot(index: 0, kind: .warm, name: "Baseline"),
            makeSnapshot(index: 1, kind: .warm, name: "Baseline"),
        ]
        let (vc, instance) = makeEphemeralController(snapshots: snapshots, ephemeral: true)
        let popUp = try #require(firstPopUp(action: "ephemeralBaselineChanged", in: vc.view))

        #expect(popUp.itemArray.count == 2)
        #expect(
            (popUp.selectedItem?.representedObject as? UUID)
                == instance.hostState.ephemeralBaselineSnapshotID)
    }

    @Test("A warm baseline says the VM comes back suspended")
    func ephemeralWarmBaselineCaptionIsShown() {
        let (vc, _) = makeEphemeralController(snapshotCount: 1, ephemeral: true, kind: .warm)

        #expect(visibleLabel(EphemeralModeCopy.baselineCaption(for: .warm), in: vc.view))
        #expect(!visibleLabel(EphemeralModeCopy.baselineCaption(for: .cold), in: vc.view))
    }

    @Test("The baseline caption starts at the Baseline snapshot title's edge")
    func ephemeralBaselineCaptionAlignsWithItsRow() throws {
        let (vc, _) = makeEphemeralController(snapshotCount: 1, ephemeral: true)
        vc.view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        vc.view.layoutSubtreeIfNeeded()

        let caption = try #require(
            findLabel(withText: EphemeralModeCopy.baselineCaption(for: .warm), in: vc.view))
        let title = try #require(findLabel(withText: "Baseline snapshot", in: vc.view))
        let card = try #require(enclosingGroupedFormCard(of: caption))
        #expect(try alignmentRect(of: caption, in: card).minX == alignmentRect(of: title, in: card).minX)
    }

    /// The caption is the selected baseline's, so moving the choice to a
    /// different kind moves the caption with it.
    @Test("Choosing a cold baseline swaps the caption")
    func ephemeralBaselineCaptionFollowsTheSelection() throws {
        let viewModel = makeViewModel()
        let (vc, instance) = makeEphemeralController(
            snapshots: [
                makeSnapshot(index: 0, kind: .warm), makeSnapshot(index: 1, kind: .cold),
            ], ephemeral: true, viewModel: viewModel)
        let popUp = try #require(firstPopUp(action: "ephemeralBaselineChanged", in: vc.view))

        // Newest first, so item 0 is the cold one; the move is confirmed.
        let cold = try #require(popUp.itemArray[0].representedObject as? UUID)
        ConsentedSettingWrite(instance: instance, viewModel: viewModel, refresh: {}).write(
            VMConfigurationKeyRegistry.ephemeralBaseline.assigning(cold.uuidString),
            confirmingIn: nil, consent: Consent([.setEphemeralBaseline]))
        // The written configuration re-enters `apply()` through the model's own
        // observation in the app; here the render is asked for directly.
        vc.viewDidAppear()

        #expect(visibleLabel(EphemeralModeCopy.baselineCaption(for: .cold), in: vc.view))
        #expect(!visibleLabel(EphemeralModeCopy.baselineCaption(for: .warm), in: vc.view))
    }

    // MARK: - Startup capacity warning

    /// Builds a controller over a library holding `markedMacOSVMs` macOS VMs
    /// marked to start automatically — the VM under test among them when it is
    /// itself a macOS guest.
    private func makeStartupController(guestOS: VMGuestOS, markedMacOSVMs: Int) -> (
        VMSettingsViewController, VMInstance
    ) {
        let viewModel = makeViewModel()
        let marksItself = guestOS == .macOS && markedMacOSVMs > 0
        let instance = viewModel.library.admitFixture(
            guestOS: guestOS, hostState: VMHostState(startsAutomaticallyOnLaunch: marksItself))
        for index in 0..<(markedMacOSVMs - (marksItself ? 1 : 0)) {
            viewModel.library.admitFixture(
                guestOS: .macOS, hostState: VMHostState(startsAutomaticallyOnLaunch: true)
            ) {
                $0.name = "Marked \(index)"
            }
        }
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)
        return (vc, instance)
    }

    @Test("Three marked macOS VMs warn that macOS won't run them all")
    func startupWarnsOverTheMacOSLimit() throws {
        let (vc, _) = makeStartupController(guestOS: .macOS, markedMacOSVMs: 3)
        let warning = try #require(
            VMOverviewResolver.autoStartCapacityWarning(
                isMacOSGuest: true, markedMacOSVMCount: 3))

        #expect(visibleLabel(warning, in: vc.view))
    }

    /// One row of the capacity-warning decision table.
    struct CapacityCase: Sendable, CustomStringConvertible {
        let isMacOSGuest: Bool
        let marked: Int
        let warns: Bool

        init(_ isMacOSGuest: Bool, _ marked: Int, _ warns: Bool) {
            self.isMacOSGuest = isMacOSGuest
            self.marked = marked
            self.warns = warns
        }

        var description: String {
            "\(isMacOSGuest ? "macOS" : "Linux") guest, \(marked) marked → "
                + (warns ? "warns" : "silent")
        }
    }

    @Test(
        "autoStartCapacityWarning fires only for a macOS guest over the limit",
        arguments: [
            CapacityCase(true, 0, false),
            CapacityCase(true, 1, false),
            CapacityCase(true, 2, false),
            CapacityCase(true, 3, true),
            CapacityCase(true, 7, true),
            // A Linux guest doesn't count against the macOS cap and can do
            // nothing about it from its own pane.
            CapacityCase(false, 3, false),
            CapacityCase(false, 7, false),
        ])
    func autoStartCapacityWarningMatrix(testCase: CapacityCase) {
        let warning = VMOverviewResolver.autoStartCapacityWarning(
            isMacOSGuest: testCase.isMacOSGuest, markedMacOSVMCount: testCase.marked)

        #expect((warning != nil) == testCase.warns)
        if let warning {
            // The vendor's claim, at the vendor's strength.
            #expect(warning.contains("macOS runs at most two at once"))
            #expect(warning.hasPrefix("\(testCase.marked) macOS virtual machines"))
        }
    }

    // MARK: - Machine ID

    private static let sharedMachineIDNote = "Same machine ID as \u{201C}Twin\u{201D}."

    @Test("A VM with a machine ID shows its fingerprint, the whole digest in the tooltip")
    func machineIDRowShowsTheFingerprint() throws {
        let identity = Data([2, 7, 1, 8])
        let viewModel = makeViewModel()
        let instance = viewModel.library.registerFixture { $0.genericMachineIdentifierData = identity }
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)

        let fingerprint = MachineIdentity.generic(identity).fingerprint
        #expect(visibleLabel("Machine ID", in: vc.view))
        let value = try #require(panelLabel(fingerprint.short, in: vc))
        #expect(isVisible(value, within: vc.view))
        #expect(value.toolTip == fingerprint.digest)
        #expect(value.font?.isFixedPitch == true)
        #expect(!visibleLabel(Self.sharedMachineIDNote, in: vc.view))
        #expect(separatesEveryRow(generalCardLayout(in: vc)))
    }

    @Test("Another VM arriving with the same machine ID is named under the Machine ID row")
    func sharedMachineIDFollowsTheLibrary() async throws {
        let identity = Data([2, 7, 1, 8])
        let viewModel = makeViewModel()
        let instance = viewModel.library.registerFixture { $0.genericMachineIdentifierData = identity }
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)
        #expect(!visibleLabel(Self.sharedMachineIDNote, in: vc.view))

        viewModel.library.registerFixture(name: "Twin") { $0.genericMachineIdentifierData = identity }
        // The pane's repaint is the main-actor task the change enqueued.
        await drainMainQueue()

        #expect(visibleLabel(Self.sharedMachineIDNote, in: vc.view))
        let title = try #require(panelLabel("Machine ID", in: vc))
        let owner = try #require(
            sequence(first: title as NSView, next: \.superview).first { $0 is GroupedFormNotedRow })
        #expect(visibleLabel(Self.sharedMachineIDNote, in: owner))
    }
}
