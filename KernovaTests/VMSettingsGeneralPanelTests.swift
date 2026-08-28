import AVFoundation
import AppKit
import Testing
import Virtualization

@testable import Kernova

/// The General panel's own behavior, drilled into through the shell.
@Suite("VM Settings General Panel Tests", .serialized, .admissionGated)
@MainActor
struct VMSettingsGeneralPanelTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmsettings.general")

    private func makeViewModel() -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences)
    }

    private func makeInstance(guestOS: VMGuestOS) -> VMInstance {
        makeSettingsInstance(guestOS: guestOS)
    }

    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = nil
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
        #expect(visibleLabel(VMSettingsGeneralPanelViewController.autoStartOrderCaption, in: vc.view))
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
            VMSettingsGeneralPanelViewController.autoStartCapacityWarning(
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
        let warning = VMSettingsGeneralPanelViewController.autoStartCapacityWarning(
            isMacOSGuest: testCase.isMacOSGuest, markedMacOSVMCount: testCase.marked)

        #expect((warning != nil) == testCase.warns)
        if let warning {
            // The vendor's claim, at the vendor's strength.
            #expect(
                warning.contains("macOS allows at most two macOS virtual machines to run at once"))
            #expect(warning.contains("\(testCase.marked) macOS virtual machines"))
        }
    }
}
