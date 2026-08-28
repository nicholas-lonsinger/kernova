import AVFoundation
import AppKit
import Testing
import Virtualization

@testable import Kernova

@Suite("VMSettingsViewController Tests", .serialized, .admissionGated)
@MainActor
struct VMSettingsViewControllerTests {
    // MARK: - Fixtures

    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmsettings")

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

    private func makeInstance(guestOS: VMGuestOS) -> VMInstance {
        let config = VMConfiguration(
            name: "Test VM", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    /// Builds the controller and runs its appearance lifecycle so `apply()` has
    /// populated control values and enabled state.
    ///
    /// `category` opens that panel, which is what puts its rows on screen — the
    /// pane starts on the overview, where every panel is hidden.
    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = nil
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: guestOS)
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        if let category { vc.showCategory(category) }
        return (vc, instance, viewModel)
    }

    // MARK: - Per-row delete confirmation prompt

    @Test("Internal disk delete offers Move-to-Trash only (no keep-file)")
    func deletePromptInternalDisk() {
        let prompt = VMSettingsViewController.attachmentDeletePrompt(
            label: "Extra Disk", isInternal: true, isMainDisk: false,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash])
        #expect(prompt.title.contains("Extra Disk"))
    }

    @Test("Main disk delete warns it's the startup disk")
    func deletePromptMainDisk() {
        let prompt = VMSettingsViewController.attachmentDeletePrompt(
            label: "Main Disk", isInternal: true, isMainDisk: true,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash])
        #expect(prompt.message.contains("startup disk"))
    }

    @Test("Private external delete offers both Move-to-Trash and Remove-from-VM")
    func deletePromptPrivateExternal() {
        let prompt = VMSettingsViewController.attachmentDeletePrompt(
            label: "Scratch", isInternal: false, isMainDisk: false,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash, .removeFromVM])
    }

    @Test("Shared external delete hard-blocks trashing (Remove-from-VM only) and names the VMs")
    func deletePromptSharedExternal() {
        let prompt = VMSettingsViewController.attachmentDeletePrompt(
            label: "Installer", isInternal: false, isMainDisk: false,
            isGuestAgent: false, sharedVMNames: ["macOS Copy", "Linux"])
        #expect(prompt.actions == [.removeFromVM])
        #expect(prompt.message.contains("macOS Copy"))
        #expect(prompt.message.contains("Linux"))
    }

    @Test("Guest Agent delete only detaches and says the installer isn't deleted")
    func deletePromptGuestAgent() {
        let prompt = VMSettingsViewController.attachmentDeletePrompt(
            label: "Kernova Guest Agent", isInternal: false, isMainDisk: false,
            isGuestAgent: true, sharedVMNames: [])
        #expect(prompt.actions == [.removeFromVM])
        #expect(prompt.message.contains("isn't deleted"))
    }

    // MARK: - Attachment row notes

    private func storageRow(in view: NSView) -> AttachmentRowView? {
        firstSubview(AttachmentRowView.self, in: view)
    }

    @Test("The attachment context menu offers Edit Notes between Rename and Get Info")
    func attachmentMenuOffersEditNotes() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        let row = storageRow(in: vc.view)
        let menu = row?.contextMenu?()

        let titles = menu?.items.map(\.title) ?? []
        let renameIndex = titles.firstIndex(of: "Rename")
        let notesIndex = titles.firstIndex(of: "Edit Notes")
        let infoIndex = titles.firstIndex(of: "Get Info")
        #expect(renameIndex != nil && notesIndex != nil && infoIndex != nil)
        if let renameIndex, let notesIndex, let infoIndex {
            #expect(renameIndex < notesIndex)
            #expect(notesIndex < infoIndex)
        }
        #expect(menu?.items.first { $0.title == "Edit Notes" }?.isEnabled == true)
    }

    @Test("Edit Notes and Rename are disabled on a read-only VM's storage row")
    func attachmentMenuEditNotesFollowsReadOnly() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: true)
        let row = storageRow(in: vc.view)
        let menu = row?.contextMenu?()

        #expect(menu?.items.first { $0.title == "Edit Notes" }?.isEnabled == false)
        #expect(menu?.items.first { $0.title == "Rename" }?.isEnabled == false)
    }

    @Test("Edit Notes on the context menu begins inline editing on the row")
    func attachmentMenuEditNotesBeginsEditing() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        let window = showInTestWindow(vc.view, size: NSSize(width: 600, height: 800))
        defer { window.close() }
        let row = storageRow(in: vc.view)
        let menu = row?.contextMenu?()
        let editNotes = menu?.items.first { $0.title == "Edit Notes" }

        editNotes.map { _ = $0.target?.perform($0.action, with: $0) }

        let editing = allSubviews(InlineEditableLabel.self, in: vc.view) { $0.isEditable }
        #expect(!editing.isEmpty)
    }

    // MARK: - Guest Agent visibility

    @Test("Guest Agent section is present for macOS guests")
    func guestAgentPresentForMacOS() {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(containsLabel("Forward guest logs", in: vc.view))
    }

    @Test("Guest Agent section is absent for Linux guests")
    func guestAgentAbsentForLinux() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(!containsLabel("Forward guest logs", in: vc.view))
    }

    // MARK: - Agent-dependent grouping (#398)

    @Test("Clipboard Sharing nests in the agent group on macOS, standalone on Linux")
    func clipboardGroupingByGuestOS() {
        // macOS: the row is nested in the Guest Agent group, with no standalone
        // "Clipboard" section header (guards against re-adding the sibling section).
        let (macVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(containsLabel("Clipboard sharing", in: macVC.view))
        #expect(!containsLabel("Clipboard", in: macVC.view))

        // Linux: SPICE clipboard keeps its own standalone section header.
        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(containsLabel("Clipboard sharing", in: linuxVC.view))
        #expect(containsLabel("Clipboard", in: linuxVC.view))
    }

    @Test("Agent-dependency caption appears for macOS but not Linux")
    func agentDependencyCaptionMacOSOnly() {
        let caption = VMSettingsViewController.agentDependencyCaption

        let (macVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(containsLabel(caption, in: macVC.view))

        // Linux clipboard is SPICE-based, so the agent-dependency cue must not appear.
        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(!containsLabel(caption, in: linuxVC.view))
    }

    // MARK: - General card OS rows

    private func makeOSRowsController(
        guestOS: VMGuestOS,
        installedImage: InstalledImage? = nil,
        lastSeenGuestOSVersion: String? = nil
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: guestOS)
        instance.configuration.installedImage = installedImage
        instance.configuration.lastSeenGuestOSVersion = lastSeenGuestOSVersion
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)
        return (vc, instance, viewModel)
    }

    @Test("A macOS VM that knows both shows the install record and the agent report side by side")
    func osRowsBothKnown() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .macOS,
            installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"),
            lastSeenGuestOSVersion: "Version 26.6 (Build 25G12)")

        #expect(visibleLabel("Installed version", in: vc.view))
        #expect(visibleLabel("macOS 26.5.2 (25F84)", in: vc.view))
        #expect(visibleLabel("OS version", in: vc.view))
        #expect(visibleLabel("26.6", in: vc.view))
    }

    @Test("A macOS VM with no agent shows only what the install recorded")
    func osRowsInstallRecordOnly() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .macOS,
            installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"))

        #expect(visibleLabel("Installed version", in: vc.view))
        #expect(!visibleLabel("OS version", in: vc.view))
    }

    @Test("A macOS VM Kernova did not install shows only what the agent reports")
    func osRowsAgentReportOnly() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .macOS, lastSeenGuestOSVersion: "26.6")

        #expect(!visibleLabel("Installed version", in: vc.view))
        #expect(visibleLabel("OS version", in: vc.view))
    }

    @Test("A macOS VM that knows neither shows neither row")
    func osRowsNeitherKnown() {
        let (vc, _, _) = makeOSRowsController(guestOS: .macOS)

        #expect(!visibleLabel("Installed version", in: vc.view))
        #expect(!visibleLabel("OS version", in: vc.view))
    }

    @Test("A Linux VM names the attached media and never an OS Version row")
    func osRowsLinuxCatalogImage() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .linux,
            installedImage: .linuxCatalogImage(
                distribution: "Ubuntu Desktop", version: "26.04 LTS"))

        #expect(visibleLabel("Installer image", in: vc.view))
        #expect(visibleLabel("Ubuntu Desktop 26.04 LTS", in: vc.view))
        // Booting that ISO is not installing from it — the guest's own
        // installer can write another distribution, or nothing at all — so the
        // row must never claim the install happened.
        #expect(!containsLabel("Installed version", in: vc.view))
        // Linux guests have no Kernova agent, so the row is never even built.
        #expect(!containsLabel("OS version", in: vc.view))
    }

    @Test("A Linux VM set up from a URL shows no OS rows at all")
    func osRowsLinuxWithoutRecord() {
        let (vc, _, _) = makeOSRowsController(guestOS: .linux)

        #expect(!visibleLabel("Installer image", in: vc.view))
        #expect(!containsLabel("OS version", in: vc.view))
    }

    /// The General card's visible run of rows and hairlines, `true` for a
    /// hairline — collapsible rows expanded, hidden views dropped.
    ///
    /// Scoped to the General panel: the overview's General card states some of
    /// the same rows and would match first.
    private func generalCardLayout(in vc: VMSettingsViewController) -> [Bool] {
        // The card's content stack is the one holding hairlines directly, which
        // no section or form stack does.
        guard let panel = vc.panelForTesting(.general) else {
            Issue.record("Expected a General panel")
            return []
        }
        guard
            let content = firstSubview(
                NSStackView.self, in: panel,
                where: { stack in
                    stack.arrangedSubviews.contains { $0 is NSBox }
                        && findLabel(withText: "Boot mode", in: stack) != nil
                })
        else {
            Issue.record("Expected a General card content stack")
            return []
        }
        return content.arrangedSubviews.filter { !$0.isHidden }.flatMap { view -> [Bool] in
            guard let collapsible = view as? GroupedFormCollapsibleRow else { return [view is NSBox] }
            return collapsible.arrangedSubviews.filter { !$0.isHidden }.map { $0 is NSBox }
        }
    }

    /// Whether a card's rows and hairlines strictly alternate, starting and
    /// ending on a row — the shape a hidden row must not disturb.
    private func separatesEveryRow(_ layout: [Bool]) -> Bool {
        layout.first == false && layout.last == false
            && zip(layout, layout.dropFirst()).allSatisfy { $0 != $1 }
    }

    @Test("Hidden OS rows take their separators with them")
    func osRowsLeaveNoStrandedSeparator() {
        // Every combination, since each leaves a different run of rows behind.
        let noRows = makeOSRowsController(guestOS: .macOS).0
        #expect(separatesEveryRow(generalCardLayout(in: noRows)))

        let installOnly = makeOSRowsController(
            guestOS: .macOS, installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84")
        ).0
        #expect(separatesEveryRow(generalCardLayout(in: installOnly)))

        let agentOnly = makeOSRowsController(guestOS: .macOS, lastSeenGuestOSVersion: "26.6").0
        #expect(separatesEveryRow(generalCardLayout(in: agentOnly)))

        let bothRows = makeOSRowsController(
            guestOS: .macOS, installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"),
            lastSeenGuestOSVersion: "26.6"
        ).0
        #expect(separatesEveryRow(generalCardLayout(in: bothRows)))
        // Both OS rows really are in the run the check passed on.
        #expect(generalCardLayout(in: bothRows).count == generalCardLayout(in: noRows).count + 4)
    }

    @Test("A first agent report reveals the OS Version row without rebuilding the form")
    func osVersionRowAppearsOnFirstReport() {
        let (vc, instance, viewModel) = makeOSRowsController(guestOS: .macOS)
        #expect(!visibleLabel("OS version", in: vc.view))

        instance.configuration.lastSeenGuestOSVersion = "26.6"
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)

        #expect(visibleLabel("OS version", in: vc.view))
        #expect(visibleLabel("26.6", in: vc.view))
    }

    // MARK: - Column and identity header

    @Test("A wide detail pane holds the form at the capped column width")
    func formTakesTheCappedColumn() throws {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        vc.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        vc.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(firstSubview(NSScrollView.self, in: vc.view))
        let form = try #require(scrollView.documentView?.subviews.first)
        #expect(form.frame.width == GroupedFormStyle.columnWidth)
        // The pinned header takes its own height and the form scrolls under it.
        #expect(scrollView.frame.height > 0)
        #expect(scrollView.frame.height < vc.view.frame.height)
    }

    @Test("The identity header leads the form, naming the VM")
    func identityHeaderLeadsTheForm() throws {
        let (vc, instance, _) = makeController(guestOS: .macOS, isReadOnly: false)

        let header = try #require(firstSubview(VMIdentityHeaderView.self, in: vc.view))
        #expect(findLabel(withText: instance.name, in: header) != nil)
    }

    // MARK: - Read-only lock behavior

    @Test("Read-only disables lockable controls but not hot-toggleable ones")
    func readOnlyDisablesLockableControls() {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: true)

        // The network Mode picker is lockable → disabled while read-only.
        #expect(networkModePopUp(in: vc.view)?.isEnabled == false)

        // Clipboard is hot-toggleable → stays enabled.
        let clipboard = firstSwitch(action: "clipboardToggled", in: vc.view)
        #expect(clipboard?.isEnabled == true)
    }

    @Test("Lockable controls are enabled when editable")
    func editableEnablesLockableControls() {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(networkModePopUp(in: vc.view)?.isEnabled == true)
    }

    @Test("Section lock hints are visible only while read-only")
    func lockHintVisibilityTracksReadOnly() throws {
        let (readOnlyVC, _, _) = makeController(guestOS: .macOS, isReadOnly: true, category: .system)
        let readOnlyPanel = try #require(readOnlyVC.panelForTesting(.system))
        let shown = lockHints(in: readOnlyPanel)
        #expect(!shown.isEmpty)
        #expect(shown.allSatisfy { !$0.isHidden })

        let (editableVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false, category: .system)
        let editablePanel = try #require(editableVC.panelForTesting(.system))
        let hidden = lockHints(in: editablePanel)
        #expect(!hidden.isEmpty)
        #expect(hidden.allSatisfy { $0.isHidden })
    }

    @Test("No page-level lock banner in either state")
    func noLockBannerInEitherState() {
        for isReadOnly in [true, false] {
            let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: isReadOnly)
            #expect(
                findLabel(
                    containing: "locked while the VM is running", in: vc.view) == nil)
        }
    }

    @Test("A locked row dims while read-only and is undimmed when editable")
    func lockedRowDimsWhileReadOnly() throws {
        let (readOnlyVC, _, _) = makeController(guestOS: .macOS, isReadOnly: true, category: .system)
        let readOnlyPanel = try #require(readOnlyVC.panelForTesting(.system))
        let locked = try #require(row(labeled: "CPU cores", in: readOnlyPanel))
        #expect(locked.alphaValue == Alpha.disabled)

        let (editableVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false, category: .system)
        let editablePanel = try #require(editableVC.panelForTesting(.system))
        let editable = try #require(row(labeled: "CPU cores", in: editablePanel))
        #expect(editable.alphaValue == 1)
    }

    @Test("The auto-resize row stays undimmed inside a locked Display card")
    func hotToggleableRowStaysUndimmed() throws {
        for isReadOnly in [true, false] {
            let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: isReadOnly, category: .system)
            let panel = try #require(vc.panelForTesting(.system))
            let autoResize = try #require(
                row(labeled: "Automatically resize with window", in: panel))
            #expect(autoResize.alphaValue == 1)
        }
    }

    @Test("A live-switchable Network section hides its hint and leaves the Mode row undimmed")
    func liveSwitchableNetworkRowStaysUndimmed() throws {
        let (vc, _) = makeNetworkController(isReadOnly: true, status: .running)
        let panel = try #require(vc.panelForTesting(.network))
        let modeRow = try #require(row(labeled: "Mode", in: panel))
        #expect(modeRow.alphaValue == 1)
        #expect(networkModePopUp(in: vc.view)?.isEnabled == true)
        #expect(panelHeaderLockHints(in: vc).allSatisfy { $0.isHidden })
    }

    @Test("A stopped VM's Network Mode row dims with the rest of its section")
    func stoppedNetworkModeRowFollowsTheLock() throws {
        let (vc, _) = makeNetworkController(isReadOnly: true, status: .stopped)
        let panel = try #require(vc.panelForTesting(.network))
        let modeRow = try #require(row(labeled: "Mode", in: panel))
        #expect(modeRow.alphaValue == Alpha.disabled)
    }

    // MARK: - Config write-back

    @Test("Toggling Clipboard Sharing writes back to the configuration")
    func clipboardToggleWritesConfig() {
        let (vc, instance, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(instance.configuration.clipboardSharingEnabled == false)

        guard let clipboard = firstSwitch(action: "clipboardToggled", in: vc.view) else {
            Issue.record("Expected a clipboard switch")
            return
        }
        clipboard.state = .on
        clipboard.sendAction(clipboard.action, to: clipboard.target)

        #expect(instance.configuration.clipboardSharingEnabled == true)
    }

    // MARK: - Launch auto-start

    @Test("The Startup toggle reflects the configuration")
    func autoStartSwitchReflectsConfiguration() {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: .linux)
        instance.configuration.startsAutomaticallyOnLaunch = true
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()

        #expect(firstSwitch(action: "autoStartToggled", in: vc.view)?.state == .on)
    }

    @Test("Toggling the Startup switch writes back to the configuration")
    func autoStartToggleWritesConfig() {
        let (vc, instance, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(instance.configuration.startsAutomaticallyOnLaunch == false)

        guard let autoStart = firstSwitch(action: "autoStartToggled", in: vc.view) else {
            Issue.record("Expected a Startup switch")
            return
        }
        autoStart.state = .on
        autoStart.sendAction(autoStart.action, to: autoStart.target)

        #expect(instance.configuration.startsAutomaticallyOnLaunch == true)
    }

    /// The flag is consumed once at app launch and reaches no
    /// `VZVirtualMachineConfiguration`, so it must stay editable while the VM
    /// runs — unlike every control the read-only banner locks.
    @Test("The Startup toggle stays editable while the VM is running")
    func autoStartSwitchStaysEnabledWhenReadOnly() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: true)
        #expect(firstSwitch(action: "autoStartToggled", in: vc.view)?.isEnabled == true)
    }

    @Test("The Startup section says which order the marked VMs start in")
    func startupSectionStatesTheStartOrder() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: false, category: .general)
        #expect(visibleLabel(VMSettingsViewController.autoStartOrderCaption, in: vc.view))
    }

    // MARK: - Ephemeral Mode

    /// Builds a settings pane over a VM carrying `snapshotCount` snapshots, the
    /// oldest of which is the Current one.
    private func makeEphemeralController(
        snapshotCount: Int, ephemeral: Bool, isReadOnly: Bool = false
    ) -> (VMSettingsViewController, VMInstance) {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: .linux)
        let snapshots = (0..<snapshotCount).map {
            VMSnapshot(
                name: "Snapshot \($0)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 60))
        }
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: snapshots, currentID: snapshots.first?.id)
        if ephemeral, let baseline = snapshots.first {
            instance.configuration.applyEphemeralMode(enabled: true, baseline: baseline.id)
        }
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)
        return (vc, instance)
    }

    @Test("The Ephemeral toggle is off and disabled for a VM with no snapshots")
    func ephemeralToggleDisabledWithoutSnapshots() {
        let (vc, _) = makeEphemeralController(snapshotCount: 0, ephemeral: false)
        let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view)

        #expect(toggle?.state == .off)
        #expect(toggle?.isEnabled == false)
        #expect(visibleLabel(EphemeralModeCopy.noSnapshotsCaption, in: vc.view))
    }

    @Test("One snapshot is enough to offer the mode")
    func ephemeralToggleEnabledWithASnapshot() {
        let (vc, _) = makeEphemeralController(snapshotCount: 1, ephemeral: false)

        let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view)
        #expect(toggle?.isEnabled == true)
        #expect(toggle?.alphaValue == 1)
        #expect(!visibleLabel(EphemeralModeCopy.noSnapshotsCaption, in: vc.view))
    }

    @Test("The unofferable Ephemeral toggle is dimmed, not just inert")
    func ephemeralToggleDimsWhenUnofferable() {
        let (vc, _) = makeEphemeralController(snapshotCount: 0, ephemeral: false)
        let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view)
        #expect(toggle?.alphaValue ?? 1 < 1)
    }

    /// A VM already in the mode can always be taken back out, so the switch
    /// stays live even once its manifest can no longer offer a baseline.
    @Test("A VM already in the mode keeps a live toggle with no snapshots")
    func ephemeralToggleStaysLiveWhenAlreadyOn() {
        let (vc, instance) = makeEphemeralController(snapshotCount: 1, ephemeral: true)
        instance.snapshotManifest = VMSnapshotManifest()
        // Re-runs `apply()` over the mutated manifest.
        vc.viewDidAppear()

        let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view)
        #expect(toggle?.isEnabled == true)
        #expect(toggle?.alphaValue == 1)
    }

    @Test("Turning the mode on defaults the baseline to the current snapshot")
    func ephemeralToggleDefaultsToCurrent() {
        let (vc, instance) = makeEphemeralController(snapshotCount: 2, ephemeral: false)
        guard let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view) else {
            Issue.record("Expected an Ephemeral Mode switch")
            return
        }

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(instance.configuration.ephemeralModeEnabled)
        #expect(
            instance.configuration.ephemeralBaselineSnapshotID
                == instance.snapshotManifest.currentID)
    }

    @Test("Turning the mode off clears the baseline")
    func ephemeralToggleOffClearsTheBaseline() {
        let (vc, instance) = makeEphemeralController(snapshotCount: 2, ephemeral: true)
        guard let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view) else {
            Issue.record("Expected an Ephemeral Mode switch")
            return
        }

        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(!instance.configuration.ephemeralModeEnabled)
        #expect(instance.configuration.ephemeralBaselineSnapshotID == nil)
    }

    @Test("The baseline menu lists the VM's snapshots and selects the chosen one")
    func ephemeralBaselineMenuListsSnapshots() {
        let (vc, instance) = makeEphemeralController(snapshotCount: 3, ephemeral: true)
        guard let popUp = firstPopUp(action: "ephemeralBaselineChanged", in: vc.view) else {
            Issue.record("Expected a Baseline snapshot popup")
            return
        }

        #expect(popUp.itemArray.count == 3)
        #expect(
            (popUp.selectedItem?.representedObject as? UUID)
                == instance.configuration.ephemeralBaselineSnapshotID)
    }

    @Test("Choosing another snapshot moves the baseline")
    func ephemeralBaselineSelectionWritesConfig() {
        let (vc, instance) = makeEphemeralController(snapshotCount: 3, ephemeral: true)
        guard let popUp = firstPopUp(action: "ephemeralBaselineChanged", in: vc.view) else {
            Issue.record("Expected a Baseline snapshot popup")
            return
        }
        // Rows render newest first, so the first item is not the Current one.
        let newest = popUp.itemArray[0].representedObject as? UUID

        popUp.select(popUp.itemArray[0])
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.ephemeralBaselineSnapshotID == newest)
        #expect(instance.configuration.ephemeralModeEnabled)
    }

    /// The flag is read at power-off and reaches no `VZVirtualMachineConfiguration`,
    /// so it stays editable while the VM runs — and a running ephemeral VM is
    /// exactly where a user reaches for the switch.
    @Test("The Ephemeral toggle stays editable while the VM is running")
    func ephemeralToggleStaysEnabledWhenReadOnly() {
        let (vc, _) = makeEphemeralController(
            snapshotCount: 1, ephemeral: false, isReadOnly: true)

        #expect(firstSwitch(action: "ephemeralModeToggled", in: vc.view)?.isEnabled == true)
    }

    @Test("The Startup card explains what an ephemeral VM does")
    func ephemeralCaptionIsShown() {
        let (vc, _) = makeEphemeralController(snapshotCount: 1, ephemeral: true)
        #expect(visibleLabel(EphemeralModeCopy.settingsCaption, in: vc.view))
    }

    // MARK: - Startup capacity warning

    /// Builds a controller over a library holding `markedMacOSVMs` macOS VMs
    /// marked to start automatically — the VM under test among them when it is
    /// itself a macOS guest.
    private func makeStartupController(guestOS: VMGuestOS, markedMacOSVMs: Int) -> (
        VMSettingsViewController, VMInstance
    ) {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: guestOS)
        var library = [instance]
        var remaining = markedMacOSVMs
        if guestOS == .macOS, remaining > 0 {
            instance.configuration.startsAutomaticallyOnLaunch = true
            remaining -= 1
        }
        for index in 0..<remaining {
            let other = makeInstance(guestOS: .macOS)
            other.configuration.name = "Marked \(index)"
            other.configuration.startsAutomaticallyOnLaunch = true
            library.append(other)
        }
        viewModel.instances = library
        let vc = VMSettingsViewController(
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
            VMSettingsViewController.autoStartCapacityWarning(
                isMacOSGuest: true, markedMacOSVMCount: 3))

        #expect(visibleLabel(warning, in: vc.view))
    }

    /// Whether any visible label carries the capacity warning's vendor sentence.
    ///
    /// Matched by substring rather than by whole string: the message leads with
    /// the marked count, so the exact text is only known where a warning is
    /// expected — and the absence assertions are exactly where it is not.
    private func showsMacOSCapacityWarning(in view: NSView) -> Bool {
        firstSubview(NSTextField.self, in: view) {
            $0.stringValue.contains("macOS allows at most two macOS virtual machines to run at once")
                && isVisible($0, within: view)
        } != nil
    }

    @Test("Two marked macOS VMs are within the limit and warn about nothing")
    func startupDoesNotWarnAtTheMacOSLimit() {
        let (vc, _) = makeStartupController(guestOS: .macOS, markedMacOSVMs: 2)
        #expect(!showsMacOSCapacityWarning(in: vc.view))
    }

    /// Linux guests don't count against the macOS cap, so the warning is not
    /// theirs to show even while three macOS VMs are marked.
    @Test("A Linux guest never shows the macOS capacity warning")
    func startupNeverWarnsOnALinuxGuest() {
        let (vc, _) = makeStartupController(guestOS: .linux, markedMacOSVMs: 3)
        #expect(!showsMacOSCapacityWarning(in: vc.view))
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
        let warning = VMSettingsViewController.autoStartCapacityWarning(
            isMacOSGuest: testCase.isMacOSGuest, markedMacOSVMCount: testCase.marked)

        #expect((warning != nil) == testCase.warns)
        if let warning {
            // The vendor's claim, at the vendor's strength.
            #expect(
                warning.contains("macOS allows at most two macOS virtual machines to run at once"))
            #expect(warning.contains("\(testCase.marked) macOS virtual machines"))
        }
    }

    // MARK: - Clipboard passthrough

    /// Builds a controller over a config with the given clipboard-sharing state,
    /// so passthrough-enablement gating can be exercised.
    private func makeController(guestOS: VMGuestOS, sharingEnabled: Bool) -> (
        VMSettingsViewController, VMInstance
    ) {
        let viewModel = makeViewModel()
        let config = VMConfiguration(
            name: "Test VM", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi,
            clipboardSharingEnabled: sharingEnabled)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        let vc = VMSettingsViewController(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        return (vc, instance)
    }

    @Test("The passthrough toggle appears for both guest OSes")
    func passthroughTogglePresentByGuestOS() {
        let (macVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(containsLabel("Automatic clipboard passthrough", in: macVC.view))
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: macVC.view) != nil)

        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(containsLabel("Automatic clipboard passthrough", in: linuxVC.view))
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: linuxVC.view) != nil)
    }

    @Test("The passthrough toggle is disabled until sharing is on")
    func passthroughDisabledWithoutSharing() {
        let (offVC, _) = makeController(guestOS: .macOS, sharingEnabled: false)
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: offVC.view)?.isEnabled == false)

        let (onVC, _) = makeController(guestOS: .macOS, sharingEnabled: true)
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: onVC.view)?.isEnabled == true)
    }

    /// AppKit draws a disabled `NSSwitch` that is *on* at full accent fill, so
    /// the row reads as live while it is inert; the dim is what says otherwise.
    @Test("A disabled passthrough toggle is dimmed, not just inert")
    func passthroughDimsWhenDisabled() {
        let (offVC, _) = makeController(guestOS: .macOS, sharingEnabled: false)
        let off = firstSwitch(action: "clipboardPassthroughToggled", in: offVC.view)
        #expect(off?.alphaValue ?? 1 < 1)

        let (onVC, _) = makeController(guestOS: .macOS, sharingEnabled: true)
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: onVC.view)?.alphaValue == 1)
    }

    @Test("Enabling passthrough without a window reverts and does not write")
    func passthroughEnableWithoutWindowReverts() {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        guard let toggle = firstSwitch(action: "clipboardPassthroughToggled", in: vc.view) else {
            Issue.record("Expected a passthrough switch")
            return
        }
        // The offscreen test VC has no window to host the confirmation sheet, so
        // the enable path must revert rather than silently enable.
        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(instance.configuration.clipboardPassthroughEnabled == false)
        #expect(toggle.state == .off)
    }

    @Test("Confirming the security prompt enables passthrough")
    func passthroughConfirmEnables() {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        #expect(instance.configuration.clipboardPassthroughEnabled == false)

        vc.confirmPassthroughEnableForTesting()

        #expect(instance.configuration.clipboardPassthroughEnabled == true)
    }

    @Test("Cancelling the security prompt reverts the switch and writes nothing")
    func passthroughCancelReverts() {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        guard let toggle = firstSwitch(action: "clipboardPassthroughToggled", in: vc.view) else {
            Issue.record("Expected a passthrough switch")
            return
        }
        toggle.state = .on  // user flipped it; the sheet is up

        vc.cancelPassthroughEnableForTesting()

        #expect(toggle.state == .off)
        #expect(instance.configuration.clipboardPassthroughEnabled == false)
    }

    @Test("Turning passthrough off writes immediately without confirmation")
    func passthroughDisableWritesImmediately() {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        vc.confirmPassthroughEnableForTesting()
        #expect(instance.configuration.clipboardPassthroughEnabled == true)

        guard let toggle = firstSwitch(action: "clipboardPassthroughToggled", in: vc.view) else {
            Issue.record("Expected a passthrough switch")
            return
        }
        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(instance.configuration.clipboardPassthroughEnabled == false)
    }

    @Test("The passthrough confirmation alert fires the right action per button")
    func passthroughConfirmationAlertWiring() {
        var confirmed = false
        var cancelled = false
        let alert = ClipboardPassthroughConfirmation.alert(
            onConfirm: { confirmed = true }, onCancel: { cancelled = true })

        #expect(alert.title == ClipboardPassthroughConfirmation.title)
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons.first?.role == .default)
        #expect(alert.buttons.last?.role == .cancel)

        alert.buttons.first?.action()
        #expect(confirmed && !cancelled)

        confirmed = false
        alert.buttons.last?.action()
        #expect(cancelled && !confirmed)
    }

    // MARK: - Guest agent install reminder

    @Test("The install-reminder switch is live while the prompt is on app-wide")
    func installReminderEnabledByDefault() throws {
        let (vc, instance, _) = makeController(guestOS: .macOS, isReadOnly: false)

        let toggle = try #require(firstSwitch(action: "installReminderToggled", in: vc.view))
        #expect(toggle.isEnabled)
        #expect(!visibleLabel(VMSettingsViewController.installPromptDisabledCaption, in: vc.view))

        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        #expect(instance.configuration.agentInstallNudgeDismissed == true)
    }

    /// The app-wide preference is not overridable per VM, so the switch goes
    /// inert — and says where the preference that made it inert lives, or the
    /// disabled state reads as broken.
    @Test("The app-wide preference disables the install-reminder switch and says why")
    func installReminderDisabledByAppWidePreference() throws {
        let (vc, instance, viewModel) = makeController(
            guestOS: .macOS, isReadOnly: false, category: .sharing)

        viewModel.agentInstallPromptDisabled = true
        // Stands in for the observation pass a Settings-window toggle triggers.
        vc.viewDidAppear()

        let toggle = try #require(firstSwitch(action: "installReminderToggled", in: vc.view))
        #expect(!toggle.isEnabled)
        #expect(visibleLabel(VMSettingsViewController.installPromptDisabledCaption, in: vc.view))
        // Overridden, not rewritten: the row still shows this VM's own choice.
        #expect(instance.configuration.agentInstallNudgeDismissed == false)
        #expect(toggle.state == .on)

        viewModel.agentInstallPromptDisabled = false
        vc.viewDidAppear()

        #expect(toggle.isEnabled)
        #expect(!visibleLabel(VMSettingsViewController.installPromptDisabledCaption, in: vc.view))
    }

    // MARK: - Display section

    /// Builds a controller over a config with explicit display settings.
    ///
    /// `hiDPI` defaults to the intent matching `ppi` — the self-consistent
    /// pairing manual mode maintains. Pass it to model a match-mode config whose
    /// stored trio is a previous boot's artifact.
    private func makeDisplayController(
        guestOS: VMGuestOS = .macOS,
        isReadOnly: Bool = false,
        sizesToWindow: Bool = false,
        width: Int = 1920,
        height: Int = 1200,
        ppi: Int = 144,
        hiDPI: Bool? = nil
    ) -> (VMSettingsViewController, VMInstance) {
        let viewModel = makeViewModel()
        let config = VMConfiguration(
            name: "Test VM", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi,
            displayWidth: width, displayHeight: height, displayPPI: ppi,
            displaySizesToWindow: sizesToWindow,
            displayHiDPI: hiDPI ?? DisplayBootSizing.isHiDPI(ppi: ppi))
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.system)
        return (vc, instance)
    }

    @Test("The Display section is present for both guest OSes")
    func displaySectionPresentForBothOSes() {
        for guestOS in [VMGuestOS.macOS, .linux] {
            let (vc, _) = makeDisplayController(guestOS: guestOS)
            #expect(containsLabel("Display", in: vc.view))
            #expect(containsLabel("Size display to fit window at startup", in: vc.view))
            #expect(containsLabel("Resolution", in: vc.view))
            #expect(firstPopUp(action: "displayResolutionChanged", in: vc.view) != nil)
        }
    }

    @Test("The HiDPI row is macOS-only, the auto-resize row is not")
    func hiDPIIsMacOSOnlyButAutoResizeIsNot() {
        let (macVC, _) = makeDisplayController(guestOS: .macOS)
        #expect(containsLabel("HiDPI (Retina)", in: macVC.view))
        #expect(containsLabel("Automatically resize with window", in: macVC.view))

        // Linux gets no HiDPI row — virtio scanouts carry no density.
        let (linuxVC, _) = makeDisplayController(guestOS: .linux)
        #expect(!containsLabel("HiDPI (Retina)", in: linuxVC.view))
        #expect(containsLabel("Automatically resize with window", in: linuxVC.view))
    }

    @Test("Match-window writes the flag and disables the manual controls")
    func matchWindowToggleWritesAndDisables() {
        let (vc, instance) = makeDisplayController()
        guard let match = firstSwitch(action: "displayMatchWindowToggled", in: vc.view),
            let popUp = firstPopUp(action: "displayResolutionChanged", in: vc.view)
        else {
            Issue.record("Expected the match-window switch and the resolution popup")
            return
        }
        #expect(popUp.isEnabled)

        match.state = .on
        match.sendAction(match.action, to: match.target)

        #expect(instance.configuration.displaySizesToWindow == true)
        #expect(!popUp.isEnabled)
        #expect(editableField("Width", in: vc.view)?.isEnabled == false)
        // Neither HiDPI nor auto-resize is a size control, so match mode leaves
        // both usable.
        #expect(firstSwitch(action: "displayHiDPIToggled", in: vc.view)?.isEnabled == true)
        #expect(firstSwitch(action: "displayAutoResizeToggled", in: vc.view)?.isEnabled == true)
    }

    @Test("A VM already in match-window mode builds with the size controls disabled")
    func matchWindowOnDisablesFromBuild() {
        let (vc, _) = makeDisplayController(sizesToWindow: true)

        #expect(firstPopUp(action: "displayResolutionChanged", in: vc.view)?.isEnabled == false)
        #expect(editableField("Width", in: vc.view)?.isEnabled == false)
        #expect(editableField("Height", in: vc.view)?.isEnabled == false)
        // HiDPI picks the scale the computed size is measured at, so it stays
        // usable — as does the mode switch, so the user can turn match off.
        #expect(firstSwitch(action: "displayHiDPIToggled", in: vc.view)?.isEnabled == true)
        #expect(firstSwitch(action: "displayMatchWindowToggled", in: vc.view)?.isEnabled == true)
    }

    @Test("Choosing a preset writes it and fills the size fields")
    func presetWritesResolution() {
        let (vc, instance) = makeDisplayController()
        guard let popUp = firstPopUp(action: "displayResolutionChanged", in: vc.view) else {
            Issue.record("Expected the resolution popup")
            return
        }
        popUp.selectItem(withTitle: "1440 × 900")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.displayWidth == 1440)
        #expect(instance.configuration.displayHeight == 900)
        #expect(editableField("Width", in: vc.view)?.integerValue == 1440)
        #expect(editableField("Height", in: vc.view)?.integerValue == 900)
    }

    @Test("A typed size below the floor clamps and flips the popup to Custom")
    func typedSizeClampsAndSelectsCustom() {
        let (vc, instance) = makeDisplayController()
        guard let width = editableField("Width", in: vc.view),
            let height = editableField("Height", in: vc.view),
            let popUp = firstPopUp(action: "displayResolutionChanged", in: vc.view)
        else {
            Issue.record("Expected the width, height, and resolution controls")
            return
        }
        width.integerValue = 640
        height.integerValue = 401
        commitEdit(width, on: vc)

        #expect(instance.configuration.displayWidth == 800)
        #expect(instance.configuration.displayHeight == 600)
        #expect(popUp.titleOfSelectedItem == "Custom")
    }

    @Test("In manual mode HiDPI rewrites the stored trio in both directions")
    func hiDPIRewritesResolution() {
        let (vc, instance) = makeDisplayController(width: 1280, height: 800, ppi: 144)
        guard let hiDPI = firstSwitch(action: "displayHiDPIToggled", in: vc.view) else {
            Issue.record("Expected the HiDPI switch")
            return
        }
        #expect(hiDPI.state == .off)

        hiDPI.state = .on
        hiDPI.sendAction(hiDPI.action, to: hiDPI.target)

        #expect(instance.configuration.displayHiDPI == true)
        #expect(instance.configuration.displayWidth == 2560)
        #expect(instance.configuration.displayHeight == 1600)
        #expect(instance.configuration.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
        // The fields keep showing the "looks like" size.
        #expect(editableField("Width", in: vc.view)?.integerValue == 1280)

        hiDPI.state = .off
        hiDPI.sendAction(hiDPI.action, to: hiDPI.target)

        #expect(instance.configuration.displayHiDPI == false)
        #expect(instance.configuration.displayWidth == 1280)
        #expect(instance.configuration.displayHeight == 800)
        #expect(instance.configuration.displayPPI == DisplayBootSizing.standardPixelsPerInch)
    }

    @Test("In match mode HiDPI writes only the flag")
    func hiDPIInMatchModeLeavesTheTrioAlone() {
        let (vc, instance) = makeDisplayController(
            sizesToWindow: true, width: 2800, height: 1760, ppi: 220)
        guard let hiDPI = firstSwitch(action: "displayHiDPIToggled", in: vc.view) else {
            Issue.record("Expected the HiDPI switch")
            return
        }

        hiDPI.state = .off
        hiDPI.sendAction(hiDPI.action, to: hiDPI.target)

        #expect(instance.configuration.displayHiDPI == false)
        // The trio is the last boot's artifact until the next start recomputes it.
        #expect(instance.configuration.displayWidth == 2800)
        #expect(instance.configuration.displayHeight == 1760)
        #expect(instance.configuration.displayPPI == 220)
    }

    @Test("The HiDPI switch shows the stored intent, the fields the stored size")
    func hiDPISwitchShowsIntentNotDensity() {
        let (retinaVC, _) = makeDisplayController(width: 2560, height: 1600, ppi: 220)
        #expect(firstSwitch(action: "displayHiDPIToggled", in: retinaVC.view)?.state == .on)
        // The fields show the halved "looks like" size.
        #expect(editableField("Width", in: retinaVC.view)?.integerValue == 1280)

        let (standardVC, _) = makeDisplayController(width: 1920, height: 1200, ppi: 144)
        #expect(firstSwitch(action: "displayHiDPIToggled", in: standardVC.view)?.state == .off)
        #expect(editableField("Width", in: standardVC.view)?.integerValue == 1920)

        // Match mode on a 1× host: the intent is on while the trio it last
        // booted at is not, and each control shows its own.
        let (divergentVC, _) = makeDisplayController(
            sizesToWindow: true, width: 1400, height: 880, ppi: 144, hiDPI: true)
        #expect(firstSwitch(action: "displayHiDPIToggled", in: divergentVC.view)?.state == .on)
        #expect(editableField("Width", in: divergentVC.view)?.integerValue == 1400)
    }

    @Test("Turning match-window off reconciles the trio to the HiDPI intent")
    func matchWindowOffReconcilesTrioToIntent() {
        let (vc, instance) = makeDisplayController(
            sizesToWindow: true, width: 1400, height: 880, ppi: 144, hiDPI: true)
        guard let match = firstSwitch(action: "displayMatchWindowToggled", in: vc.view) else {
            Issue.record("Expected the match-window switch")
            return
        }

        match.state = .off
        match.sendAction(match.action, to: match.target)

        // Manual mode boots at the trio, so it has to carry the intent.
        #expect(instance.configuration.displaySizesToWindow == false)
        #expect(instance.configuration.displayWidth == 2800)
        #expect(instance.configuration.displayHeight == 1760)
        #expect(instance.configuration.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
        #expect(editableField("Width", in: vc.view)?.integerValue == 1400)
    }

    @Test("Turning match-window off leaves an already-matching trio alone")
    func matchWindowOffKeepsAConsistentTrio() {
        let (vc, instance) = makeDisplayController(
            sizesToWindow: true, width: 2800, height: 1760, ppi: 220, hiDPI: true)
        guard let match = firstSwitch(action: "displayMatchWindowToggled", in: vc.view) else {
            Issue.record("Expected the match-window switch")
            return
        }

        match.state = .off
        match.sendAction(match.action, to: match.target)

        #expect(instance.configuration.displayWidth == 2800)
        #expect(instance.configuration.displayHeight == 1760)
        #expect(instance.configuration.displayPPI == 220)
    }

    @Test("A Linux VM leaving match-window mode keeps its resolution")
    func matchWindowOffIgnoresHiDPIForLinux() {
        // The flag defaults on and Linux has no HiDPI row: reconciliation must
        // not double a resolution VZ will report without any density.
        let (vc, instance) = makeDisplayController(
            guestOS: .linux, sizesToWindow: true, width: 1400, height: 880, ppi: 144, hiDPI: true)
        guard let match = firstSwitch(action: "displayMatchWindowToggled", in: vc.view) else {
            Issue.record("Expected the match-window switch")
            return
        }

        match.state = .off
        match.sendAction(match.action, to: match.target)

        #expect(instance.configuration.displayWidth == 1400)
        #expect(instance.configuration.displayHeight == 880)
        #expect(instance.configuration.displayPPI == 144)
    }

    @Test("Read-only disables the display lockables but not auto-resize")
    func readOnlyDisablesDisplayLockables() {
        for guestOS in [VMGuestOS.macOS, .linux] {
            let (vc, _) = makeDisplayController(guestOS: guestOS, isReadOnly: true)

            #expect(
                firstSwitch(action: "displayMatchWindowToggled", in: vc.view)?.isEnabled == false)
            #expect(firstPopUp(action: "displayResolutionChanged", in: vc.view)?.isEnabled == false)
            #expect(editableField("Width", in: vc.view)?.isEnabled == false)
            #expect(firstSwitch(action: "displayAutoResizeToggled", in: vc.view)?.isEnabled == true)
            if guestOS == .macOS {
                #expect(firstSwitch(action: "displayHiDPIToggled", in: vc.view)?.isEnabled == false)
            }
        }
    }

    @Test("Toggling auto-resize writes back to the configuration")
    func autoResizeToggleWritesConfig() {
        for guestOS in [VMGuestOS.macOS, .linux] {
            let (vc, instance) = makeDisplayController(guestOS: guestOS, isReadOnly: true)
            guard let toggle = firstSwitch(action: "displayAutoResizeToggled", in: vc.view) else {
                Issue.record("Expected the auto-resize switch")
                return
            }
            #expect(instance.configuration.displayAutoResizes == true)

            toggle.state = .off
            toggle.sendAction(toggle.action, to: toggle.target)

            #expect(instance.configuration.displayAutoResizes == false)
        }
    }

    @Test("A refresh leaves a size field the user is still typing in alone")
    func refreshKeepsAnInProgressSizeEdit() {
        let (vc, _) = makeDisplayController(width: 1920, height: 1200)
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        guard let width = editableField("Width", in: vc.view) else {
            Issue.record("Expected the width field")
            return
        }
        #expect(window.makeFirstResponder(width))
        guard let editor = width.currentEditor() else {
            Issue.record("Expected a field editor on the focused width field")
            return
        }
        editor.string = "1600"

        // Stands in for any observation pass — starting the VM from the toolbar
        // mutates status, which refreshes the whole pane.
        vc.viewDidAppear()

        #expect(width.currentEditor()?.string == "1600")
        // The committed value is untouched: only the editor holds the edit.
        #expect(editableField("Height", in: vc.view)?.integerValue == 1200)
    }

    @Test("The restart caption shows only while read-only")
    func restartCaptionOnlyWhileReadOnly() {
        let caption = "Takes effect on next start."

        let (readOnlyVC, _) = makeDisplayController(isReadOnly: true)
        #expect(visibleLabel(caption, in: readOnlyVC.view))

        let (editableVC, _) = makeDisplayController(isReadOnly: false)
        #expect(!visibleLabel(caption, in: editableVC.view))
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
        status: VMStatus = .stopped,
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
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: status)
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel ?? makeViewModel(), isReadOnly: isReadOnly,
            bridgedInterfaces: interfaces,
            entitlements: EntitlementService(
                reader: MockEntitlementReader(
                    granted: entitled ? ["com.apple.vm.networking"] : [])),
            vmnetNetworks: vmnetNetworks)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.network)
        return (vc, instance)
    }

    // MARK: - IP Address row

    @Test("An entitled Shared VM shows its reserved address and takes a reservation slot")
    func entitledSharedVMShowsReservedAddress() throws {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedAddresses = ["aa:bb:cc:dd:ee:ff": "192.168.64.10"]
        let (vc, _) = makeNetworkController(vmnetNetworks: vmnet)

        #expect(visibleLabel("IP address", in: vc.view))
        #expect(visibleLabel("192.168.64.10", in: vc.view))
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:ff"])
        #expect(vmnet.reservedMACs.map(\.kind) == [.shared])
    }

    @Test("An entitled Host Only VM's row reserves on the Host Only network")
    func entitledHostOnlyVMReservesOnItsNetwork() throws {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedAddresses = ["aa:bb:cc:dd:ee:ff": "192.168.128.5"]
        let (vc, _) = makeNetworkController(mode: .hostOnly, vmnetNetworks: vmnet)

        #expect(visibleLabel("192.168.128.5", in: vc.view))
        #expect(vmnet.reservedMACs.map(\.kind) == [.hostOnly])
    }

    @Test("A not-yet-derivable address renders as a placeholder, then fills in after materialization")
    func pendingAddressShowsPlaceholderAndMaterializes() async throws {
        let vmnet = MockVmnetNetworkProvider()
        let (vc, _) = makeNetworkController(vmnetNetworks: vmnet)

        #expect(visibleLabel("—", in: vc.view))
        // The address becomes derivable once the network materializes — which
        // the row kicked off itself.
        vmnet.scriptedAddresses = ["aa:bb:cc:dd:ee:ff": "192.168.64.9"]
        await networkPanel(in: vc)?.ipAddressMaterializeTaskForTesting?.value

        #expect(vmnet.materializeCount == 1)
        #expect(visibleLabel("192.168.64.9", in: vc.view))
        // The Network card states the same address: nothing else re-renders it
        // for an idle stopped VM, so the materialization has to paint both.
        let card = try #require(vc.overviewCardForTesting(.network))
        #expect(findLabel(withText: "192.168.64.9", in: card) != nil)
    }

    @Test("A failed materialization leaves the placeholder without spinning the refresh loop")
    func failedMaterializationLeavesPlaceholder() async throws {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.materializeFails = true
        let (vc, _) = makeNetworkController(vmnetNetworks: vmnet)

        await networkPanel(in: vc)?.ipAddressMaterializeTaskForTesting?.value

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

        let popUp = try #require(networkModePopUp(in: vc.view))
        #expect(popUp.itemTitles == ["Shared Network", "None"])
        #expect(popUp.titleOfSelectedItem == "Shared Network")
    }

    @Test("An entitled build lists a Bridged section with Automatic and each interface")
    func entitledPickerListsBridgedInterfaces() throws {
        let (vc, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(
                available: [Self.wiFi, Self.ethernet], primary: "en0"))

        let popUp = try #require(networkModePopUp(in: vc.view))
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

        let popUp = try #require(networkModePopUp(in: vc.view))
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

        let popUp = try #require(networkModePopUp(in: vc.view))
        #expect(popUp.titleOfSelectedItem == "Host Only (unavailable)")
        #expect(
            popUp.menu?.items.first { $0.title == "Host Only (unavailable)" }?.isEnabled == false)
        #expect(popUp.menu?.items.first { $0.title == "Host Only" } == nil)
    }

    @Test("Choosing Host Only writes the mode and mints a MAC address")
    func selectingHostOnlyWritesConfigAndMintsAMACAddress() throws {
        // From a VM created with networking off, so the MAC is minted here.
        let (vc, instance) = makeNetworkController(networkEnabled: false, macAddress: nil)
        let popUp = try #require(networkModePopUp(in: vc.view))

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

        let popUp = try #require(networkModePopUp(in: vc.view))
        #expect(popUp.itemTitles == ["Shared Network", "None"])
    }

    @Test("A host with nothing to bridge over shows one disabled placeholder")
    func emptyInterfaceListShowsDisabledPlaceholder() throws {
        let (vc, _) = makeNetworkController()

        let popUp = try #require(networkModePopUp(in: vc.view))
        let placeholder = try #require(
            popUp.menu?.items.first { $0.title == "No Bridgeable Interfaces" })
        #expect(!placeholder.isEnabled)
        // Automatic stays offered: it resolves at start, when an interface may be back.
        #expect(popUp.itemTitles.contains("Automatic"))
    }

    @Test("The interface list is rebuilt each time the menu opens")
    func menuRebuildPicksUpNewInterfaces() throws {
        let provider = MockBridgedInterfaceProvider(available: [Self.wiFi])
        let (vc, _) = makeNetworkController(interfaces: provider)
        let popUp = try #require(networkModePopUp(in: vc.view))
        #expect(!popUp.itemTitles.contains("Ethernet (en1)"))

        provider.available = [Self.wiFi, Self.ethernet]
        let menu = try #require(popUp.menu)
        menu.delegate?.menuNeedsUpdate?(menu)

        #expect(popUp.itemTitles.contains("Ethernet (en1)"))
    }

    @Test("Choosing None writes the mode, hides the MAC row, and says there's no device")
    func selectingNoneWritesConfigAndEmptiesTheCard() throws {
        let (vc, instance) = makeNetworkController()
        let popUp = try #require(networkModePopUp(in: vc.view))
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
        #expect(networkModePopUp(in: vc.view)?.titleOfSelectedItem == "None")
    }

    @Test("Choosing an interface sets the bridged mode and the interface in one gesture")
    func selectingInterfaceWritesModeAndIdentifier() throws {
        let (vc, instance) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(
                available: [Self.wiFi, Self.ethernet], primary: "en0"))
        let popUp = try #require(networkModePopUp(in: vc.view))

        popUp.selectItem(withTitle: "Ethernet (en1)")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.networkEnabled == true)
        #expect(instance.configuration.networkMode == .bridged)
        #expect(instance.configuration.bridgedInterfaceIdentifier == "en1")
    }

    @Test("Choosing Automatic clears the persisted interface")
    func selectingAutomaticClearsTheInterface() throws {
        let (vc, instance) = makeNetworkController(
            mode: .bridged, bridgedInterfaceIdentifier: "en1",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi, Self.ethernet]))
        let popUp = try #require(networkModePopUp(in: vc.view))

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
        let popUp = try #require(networkModePopUp(in: vc.view))

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

        let popUp = try #require(networkModePopUp(in: vc.view))
        let item = try #require(popUp.menu?.items.first { $0.title == "en9 (unavailable)" })
        #expect(!item.isEnabled)
        #expect(popUp.titleOfSelectedItem == "en9 (unavailable)")
    }

    @Test("An identifier remembered from an earlier bridged choice adds no entry")
    func rememberedInterfaceAddsNoEntryWhileShared() throws {
        let (vc, _) = makeNetworkController(
            mode: .shared, bridgedInterfaceIdentifier: "en9",
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]))

        let popUp = try #require(networkModePopUp(in: vc.view))
        #expect(popUp.menu?.items.first { $0.title == "en9 (unavailable)" } == nil)
        #expect(popUp.titleOfSelectedItem == "Shared Network")
    }

    @Test("An unentitled build still reports a bridged VM's mode")
    func unentitledBuildReportsABridgedVM() throws {
        let (vc, _) = makeNetworkController(mode: .bridged, entitled: false)

        let popUp = try #require(networkModePopUp(in: vc.view))
        #expect(popUp.titleOfSelectedItem == "Bridged (unavailable)")
        #expect(popUp.menu?.items.first { $0.title == "Bridged (unavailable)" }?.isEnabled == false)
    }

    @Test("Turning networking on gives a VM without a MAC address a stable one")
    func enablingNetworkingMintsAMACAddress() throws {
        // Shared Network, from a VM created with networking off.
        let (sharedVC, sharedInstance) = makeNetworkController(
            networkEnabled: false, macAddress: nil,
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"))
        let sharedPopUp = try #require(networkModePopUp(in: sharedVC.view))

        sharedPopUp.selectItem(withTitle: "Shared Network")
        sharedPopUp.sendAction(sharedPopUp.action, to: sharedPopUp.target)

        let sharedMAC = try #require(sharedInstance.configuration.macAddress)
        #expect(VZMACAddress(string: sharedMAC) != nil)

        // Bridged, from the same starting state.
        let (bridgedVC, bridgedInstance) = makeNetworkController(
            networkEnabled: false, macAddress: nil,
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"))
        let bridgedPopUp = try #require(networkModePopUp(in: bridgedVC.view))

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
        let popUp = try #require(networkModePopUp(in: vc.view))

        popUp.selectItem(withTitle: "Shared Network")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.macAddress == "aa:bb:cc:dd:ee:ff")
    }

    // MARK: - MAC Address row

    /// Ends editing the way a click outside the field does.
    /// Ends editing through the field's own delegate, so the assertion covers
    /// the wiring as well as the commit.
    private func commitEdit(_ field: NSTextField, on vc: VMSettingsViewController) {
        field.delegate?.controlTextDidEndEditing?(
            Notification(name: .init("test"), object: field))
    }

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
        commitEdit(field, on: vc)

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
            commitEdit(field, on: vc)

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
        commitEdit(field, on: vc)

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
        holder.status = .running
        let (vc, instance) = makeNetworkController(
            mode: .hostOnly, isReadOnly: true, status: .running, viewModel: viewModel)
        let popUp = try #require(networkModePopUp(in: vc.view))
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
        let popUp = try #require(networkModePopUp(in: vc.view))

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
            isReadOnly: true, status: .running)

        #expect(editableField("MAC address", in: vc.view)?.isEnabled == false)
        #expect(findButton(titled: "Generate", in: vc.view)?.isEnabled == false)
        #expect(networkModePopUp(in: vc.view)?.isEnabled == true)
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
        let popUp = try #require(networkModePopUp(in: vc.view))

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
        #expect(VMSettingsNetworkPanelViewController.normalizedMACAddress(" aa:bb:cc:dd:ee:ff\n") == "aa:bb:cc:dd:ee:ff")
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
            isReadOnly: true, status: .running)

        let popUp = try #require(networkModePopUp(in: vc.view))
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
            isReadOnly: true, status: .running)
        #expect(panelHeaderLockHints(in: liveVC).allSatisfy { $0.isHidden })

        let (savingVC, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]),
            isReadOnly: true, status: .saving)
        #expect(panelHeaderLockHints(in: savingVC).allSatisfy { !$0.isHidden })
        #expect(!panelHeaderLockHints(in: savingVC).isEmpty)
    }

    @Test("A live mode switch writes the config from the running picker")
    func runningPickerWritesALiveModeSwitch() throws {
        let (vc, instance) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi], primary: "en0"),
            isReadOnly: true, status: .running)
        let popUp = try #require(networkModePopUp(in: vc.view))

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
            isReadOnly: true, status: .running)
        #expect(networkModePopUp(in: vc.view)?.isEnabled == false)
    }

    @Test("Transitional and cold-paused states lock the picker")
    func transitionalStatesLockThePicker() throws {
        for status in [VMStatus.saving, .restoring, .paused] {
            // `.paused` with no live `VZVirtualMachine` is cold-paused — there
            // is no session to hot-swap an attachment on.
            let (vc, _) = makeNetworkController(
                interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]),
                isReadOnly: true, status: status)
            #expect(networkModePopUp(in: vc.view)?.isEnabled == false)
        }
    }

    @Test("A stopped VM keeps the fully editable picker, None included")
    func stoppedVMKeepsTheEditablePicker() throws {
        let (vc, _) = makeNetworkController(
            interfaces: MockBridgedInterfaceProvider(available: [Self.wiFi]))

        let popUp = try #require(networkModePopUp(in: vc.view))
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
            portForwardingRules: [Self.webRule], isReadOnly: true, status: .running)

        #expect(removeRuleButtons(in: vc.view).allSatisfy { !$0.isEnabled })
        #expect(findButton(titled: "Add Rule…", in: vc.view)?.isEnabled == false)
    }

    @Test("Unlocking after a session re-enables the rule controls")
    func unlockingReenablesTheRuleControls() {
        let (vc, instance) = makeNetworkController(
            portForwardingRules: [Self.webRule], isReadOnly: true, status: .running)
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

    // MARK: - Microphone permission

    /// Builds a controller whose Audio section is driven by a pinned permission
    /// status, so the denied banner does not depend on the test host's own TCC
    /// state.
    private func makeMicController(
        _ status: AVAuthorizationStatus,
        systemSettings: SystemSettingsLink = SystemSettingsLink()
    ) -> VMSettingsViewController {
        let instance = makeInstance(guestOS: .linux)
        instance.configuration.audioInputEnabled = true
        let vc = VMSettingsViewController(
            instance: instance, viewModel: makeViewModel(), isReadOnly: false,
            micPermissionStatus: { status }, systemSettings: systemSettings)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        return vc
    }

    @Test("Denied permission shows the warning banner with an Open System Settings button")
    func deniedMicShowsBannerAndButton() {
        let vc = makeMicController(.denied)

        #expect(findLabel(containing: "Microphone permission is denied", in: vc.view) != nil)
        #expect(findButton(titled: "Open System Settings", in: vc.view) != nil)
    }

    @Test("The banner's Open System Settings button opens the Microphone privacy pane")
    func deniedMicBannerButtonOpensSettings() throws {
        let recorder = URLOpenRecorder(results: [true])
        let vc = makeMicController(.denied, systemSettings: SystemSettingsLink(open: recorder.open))

        let button = try #require(findButton(titled: "Open System Settings", in: vc.view))
        button.performClick(nil)

        #expect(recorder.opened == [SystemSettingsLink.microphonePrivacyURL])
    }

    @Test("An undetermined permission explains the upcoming prompt instead of offering the link")
    func undeterminedMicShowsCaptionOnly() {
        let vc = makeMicController(.notDetermined)

        #expect(
            findLabel(
                withText: "macOS will ask for microphone permission the first time a VM uses it.",
                in: vc.view) != nil)
        #expect(findButton(titled: "Open System Settings", in: vc.view) == nil)
    }

    @Test("Granted permission shows neither the banner nor the link")
    func authorizedMicShowsNothing() {
        let vc = makeMicController(.authorized)

        #expect(findLabel(containing: "Microphone permission is denied", in: vc.view) == nil)
        #expect(findButton(titled: "Open System Settings", in: vc.view) == nil)
    }

    // MARK: - Helpers (view-tree introspection)

    /// The Network panel, for the seams it owns rather than the shell.
    private func networkPanel(in vc: VMSettingsViewController)
        -> VMSettingsNetworkPanelViewController?
    {
        vc.settingsPanelForTesting(.network) as? VMSettingsNetworkPanelViewController
    }

    private func networkModePopUp(in view: NSView) -> NSPopUpButton? {
        firstSubview(NSPopUpButton.self, in: view) {
            $0.action.map(NSStringFromSelector) == "networkModeChanged"
        }
    }

    private func firstSwitch(action name: String, in view: NSView) -> NSSwitch? {
        firstSubview(NSSwitch.self, in: view) { $0.action.map(NSStringFromSelector) == name }
    }

    private func lockHints(in view: NSView) -> [NSView] {
        allSubviews(NSStackView.self, in: view) { $0.toolTip == groupedFormLockHintText }
    }

    /// The lock hints on the open panel's header, which is where a
    /// single-section category's hint lives.
    private func panelHeaderLockHints(in vc: VMSettingsViewController) -> [NSView] {
        guard let header = firstSubview(VMSettingsPanelHeaderView.self, in: vc.view) else {
            return []
        }
        return lockHints(in: header)
    }

    /// The grouped-form row whose leading label reads `label`.
    private func row(labeled label: String, in view: NSView) -> NSView? {
        firstSubview(NSStackView.self, in: view) { stack in
            stack.arrangedSubviews.contains { ($0 as? NSTextField)?.stringValue == label }
        }
    }

    private func containsLabel(_ text: String, in view: NSView) -> Bool {
        findLabel(withText: text, in: view) != nil
    }

    /// Like ``containsLabel(_:in:)``, but only counts a label that is actually
    /// shown (no hidden label or hidden ancestor).
    private func visibleLabel(_ text: String, in view: NSView) -> Bool {
        firstSubview(NSTextField.self, in: view) {
            $0.stringValue == text && isVisible($0, within: view)
        } != nil
    }

    /// The form holds several popups, so each is found by the action it sends
    /// rather than by position in the view tree.
    private func firstPopUp(action name: String, in view: NSView) -> NSPopUpButton? {
        firstSubview(NSPopUpButton.self, in: view) { $0.action.map(NSStringFromSelector) == name }
    }

    /// The editable field in the grouped-form card row titled `label`, however
    /// deeply the row nests it (the MAC row pairs its field with a button).
    private func editableField(_ label: String, in view: NSView) -> NSTextField? {
        let row = firstSubview(NSStackView.self, in: view) { stack in
            stack.arrangedSubviews.contains { ($0 as? NSTextField)?.stringValue == label }
        }
        guard let row else { return nil }
        return findEditableField(in: row)
    }
}
