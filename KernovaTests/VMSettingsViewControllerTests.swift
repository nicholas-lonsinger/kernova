import AppKit
import Testing

@testable import Kernova

@Suite("VMSettingsViewController Tests")
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
    private func makeController(guestOS: VMGuestOS, isReadOnly: Bool) -> (
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
        #expect(containsLabel("Clipboard Sharing", in: macVC.view))
        #expect(!containsLabel("Clipboard", in: macVC.view))

        // Linux: SPICE clipboard keeps its own standalone section header.
        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(containsLabel("Clipboard Sharing", in: linuxVC.view))
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
        return (vc, instance, viewModel)
    }

    @Test("A macOS VM that knows both shows the install record and the agent report side by side")
    func osRowsBothKnown() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .macOS,
            installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"),
            lastSeenGuestOSVersion: "Version 26.6 (Build 25G12)")

        #expect(visibleLabel("Installed From", in: vc.view))
        #expect(visibleLabel("macOS 26.5.2 (25F84)", in: vc.view))
        #expect(visibleLabel("OS Version", in: vc.view))
        #expect(visibleLabel("26.6", in: vc.view))
    }

    @Test("A macOS VM with no agent shows only what the install recorded")
    func osRowsInstallRecordOnly() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .macOS,
            installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"))

        #expect(visibleLabel("Installed From", in: vc.view))
        #expect(!visibleLabel("OS Version", in: vc.view))
    }

    @Test("A macOS VM Kernova did not install shows only what the agent reports")
    func osRowsAgentReportOnly() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .macOS, lastSeenGuestOSVersion: "26.6")

        #expect(!visibleLabel("Installed From", in: vc.view))
        #expect(visibleLabel("OS Version", in: vc.view))
    }

    @Test("A macOS VM that knows neither shows neither row")
    func osRowsNeitherKnown() {
        let (vc, _, _) = makeOSRowsController(guestOS: .macOS)

        #expect(!visibleLabel("Installed From", in: vc.view))
        #expect(!visibleLabel("OS Version", in: vc.view))
    }

    @Test("A Linux VM shows the image it was installed from and never an OS Version row")
    func osRowsLinuxCatalogImage() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .linux,
            installedImage: .linuxCatalogImage(
                distribution: "Ubuntu Desktop", version: "26.04 LTS"))

        #expect(visibleLabel("Installed From", in: vc.view))
        #expect(visibleLabel("Ubuntu Desktop 26.04 LTS", in: vc.view))
        // Linux guests have no Kernova agent, so the row is never even built.
        #expect(!containsLabel("OS Version", in: vc.view))
    }

    @Test("A Linux VM installed from a URL shows no OS rows at all")
    func osRowsLinuxWithoutRecord() {
        let (vc, _, _) = makeOSRowsController(guestOS: .linux)

        #expect(!visibleLabel("Installed From", in: vc.view))
        #expect(!containsLabel("OS Version", in: vc.view))
    }

    /// The General card's visible run of rows and hairlines, `true` for a
    /// hairline — collapsible rows expanded, hidden views dropped.
    private func generalCardLayout(in view: NSView) -> [Bool] {
        // The card's content stack is the one holding hairlines directly, which
        // no section or form stack does.
        guard
            let content = firstSubview(
                NSStackView.self, in: view,
                where: { stack in
                    stack.arrangedSubviews.contains { $0 is NSBox }
                        && findLabel(withText: "Boot Mode", in: stack) != nil
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
        #expect(separatesEveryRow(generalCardLayout(in: noRows.view)))

        let installOnly = makeOSRowsController(
            guestOS: .macOS, installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84")
        ).0
        #expect(separatesEveryRow(generalCardLayout(in: installOnly.view)))

        let agentOnly = makeOSRowsController(guestOS: .macOS, lastSeenGuestOSVersion: "26.6").0
        #expect(separatesEveryRow(generalCardLayout(in: agentOnly.view)))

        let bothRows = makeOSRowsController(
            guestOS: .macOS, installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"),
            lastSeenGuestOSVersion: "26.6"
        ).0
        #expect(separatesEveryRow(generalCardLayout(in: bothRows.view)))
        // Both OS rows really are in the run the check passed on.
        #expect(generalCardLayout(in: bothRows.view).count == generalCardLayout(in: noRows.view).count + 4)
    }

    @Test("A first agent report reveals the OS Version row without rebuilding the form")
    func osVersionRowAppearsOnFirstReport() {
        let (vc, instance, viewModel) = makeOSRowsController(guestOS: .macOS)
        #expect(!visibleLabel("OS Version", in: vc.view))

        instance.configuration.lastSeenGuestOSVersion = "26.6"
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)

        #expect(visibleLabel("OS Version", in: vc.view))
        #expect(visibleLabel("26.6", in: vc.view))
    }

    // MARK: - Read-only lock behavior

    @Test("Read-only disables lockable controls but not hot-toggleable ones")
    func readOnlyDisablesLockableControls() {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: true)

        // Networking is lockable → disabled while read-only.
        let network = firstSwitch(action: "networkToggled", in: vc.view)
        #expect(network?.isEnabled == false)

        // Clipboard is hot-toggleable → stays enabled.
        let clipboard = firstSwitch(action: "clipboardToggled", in: vc.view)
        #expect(clipboard?.isEnabled == true)
    }

    @Test("Lockable controls are enabled when editable")
    func editableEnablesLockableControls() {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        let network = firstSwitch(action: "networkToggled", in: vc.view)
        #expect(network?.isEnabled == true)
    }

    @Test("Lock icons are visible only while read-only")
    func lockIconsVisibilityTracksReadOnly() {
        let (readOnlyVC, _, _) = makeController(guestOS: .macOS, isReadOnly: true)
        let shownIcons = lockIcons(in: readOnlyVC.view)
        #expect(!shownIcons.isEmpty)
        #expect(shownIcons.allSatisfy { !$0.isHidden })

        let (editableVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        let hiddenIcons = lockIcons(in: editableVC.view)
        #expect(!hiddenIcons.isEmpty)
        #expect(hiddenIcons.allSatisfy { $0.isHidden })
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

    @Test("Toggling Networking writes back to the configuration")
    func networkToggleWritesConfig() {
        let (vc, instance, _) = makeController(guestOS: .linux, isReadOnly: false)
        let initial = instance.configuration.networkEnabled

        guard let network = firstSwitch(action: "networkToggled", in: vc.view) else {
            Issue.record("Expected a networking switch")
            return
        }
        network.state = initial ? .off : .on
        network.sendAction(network.action, to: network.target)

        #expect(instance.configuration.networkEnabled == !initial)
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
        #expect(containsLabel("Automatic Clipboard Passthrough", in: macVC.view))
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: macVC.view) != nil)

        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(containsLabel("Automatic Clipboard Passthrough", in: linuxVC.view))
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: linuxVC.view) != nil)
    }

    @Test("The passthrough toggle is disabled until sharing is on")
    func passthroughDisabledWithoutSharing() {
        let (offVC, _) = makeController(guestOS: .macOS, sharingEnabled: false)
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: offVC.view)?.isEnabled == false)

        let (onVC, _) = makeController(guestOS: .macOS, sharingEnabled: true)
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: onVC.view)?.isEnabled == true)
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
        return (vc, instance)
    }

    @Test("The Display section is present for both guest OSes")
    func displaySectionPresentForBothOSes() {
        for guestOS in [VMGuestOS.macOS, .linux] {
            let (vc, _) = makeDisplayController(guestOS: guestOS)
            #expect(containsLabel("Display", in: vc.view))
            #expect(containsLabel("Size display to fit window at startup", in: vc.view))
            #expect(containsLabel("Resolution", in: vc.view))
            #expect(firstPopUp(in: vc.view) != nil)
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
            let popUp = firstPopUp(in: vc.view)
        else {
            Issue.record("Expected the match-window switch and the resolution popup")
            return
        }
        #expect(popUp.isEnabled)

        match.state = .on
        match.sendAction(match.action, to: match.target)

        #expect(instance.configuration.displaySizesToWindow == true)
        #expect(!popUp.isEnabled)
        #expect(sizeField("Width", in: vc.view)?.isEnabled == false)
        // Neither HiDPI nor auto-resize is a size control, so match mode leaves
        // both usable.
        #expect(firstSwitch(action: "displayHiDPIToggled", in: vc.view)?.isEnabled == true)
        #expect(firstSwitch(action: "displayAutoResizeToggled", in: vc.view)?.isEnabled == true)
    }

    @Test("A VM already in match-window mode builds with the size controls disabled")
    func matchWindowOnDisablesFromBuild() {
        let (vc, _) = makeDisplayController(sizesToWindow: true)

        #expect(firstPopUp(in: vc.view)?.isEnabled == false)
        #expect(sizeField("Width", in: vc.view)?.isEnabled == false)
        #expect(sizeField("Height", in: vc.view)?.isEnabled == false)
        // HiDPI picks the scale the computed size is measured at, so it stays
        // usable — as does the mode switch, so the user can turn match off.
        #expect(firstSwitch(action: "displayHiDPIToggled", in: vc.view)?.isEnabled == true)
        #expect(firstSwitch(action: "displayMatchWindowToggled", in: vc.view)?.isEnabled == true)
    }

    @Test("Choosing a preset writes it and fills the size fields")
    func presetWritesResolution() {
        let (vc, instance) = makeDisplayController()
        guard let popUp = firstPopUp(in: vc.view) else {
            Issue.record("Expected the resolution popup")
            return
        }
        popUp.selectItem(withTitle: "1440 × 900")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.displayWidth == 1440)
        #expect(instance.configuration.displayHeight == 900)
        #expect(sizeField("Width", in: vc.view)?.integerValue == 1440)
        #expect(sizeField("Height", in: vc.view)?.integerValue == 900)
    }

    @Test("A typed size below the floor clamps and flips the popup to Custom")
    func typedSizeClampsAndSelectsCustom() {
        let (vc, instance) = makeDisplayController()
        guard let width = sizeField("Width", in: vc.view),
            let height = sizeField("Height", in: vc.view),
            let popUp = firstPopUp(in: vc.view)
        else {
            Issue.record("Expected the width, height, and resolution controls")
            return
        }
        width.integerValue = 640
        height.integerValue = 401
        vc.controlTextDidEndEditing(Notification(name: .init("test"), object: width))

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
        #expect(sizeField("Width", in: vc.view)?.integerValue == 1280)

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
        #expect(sizeField("Width", in: retinaVC.view)?.integerValue == 1280)

        let (standardVC, _) = makeDisplayController(width: 1920, height: 1200, ppi: 144)
        #expect(firstSwitch(action: "displayHiDPIToggled", in: standardVC.view)?.state == .off)
        #expect(sizeField("Width", in: standardVC.view)?.integerValue == 1920)

        // Match mode on a 1× host: the intent is on while the trio it last
        // booted at is not, and each control shows its own.
        let (divergentVC, _) = makeDisplayController(
            sizesToWindow: true, width: 1400, height: 880, ppi: 144, hiDPI: true)
        #expect(firstSwitch(action: "displayHiDPIToggled", in: divergentVC.view)?.state == .on)
        #expect(sizeField("Width", in: divergentVC.view)?.integerValue == 1400)
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
        #expect(sizeField("Width", in: vc.view)?.integerValue == 1400)
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
            #expect(firstPopUp(in: vc.view)?.isEnabled == false)
            #expect(sizeField("Width", in: vc.view)?.isEnabled == false)
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
        guard let width = sizeField("Width", in: vc.view) else {
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
        #expect(sizeField("Height", in: vc.view)?.integerValue == 1200)
    }

    @Test("The restart caption shows only while read-only")
    func restartCaptionOnlyWhileReadOnly() {
        let caption = "Takes effect on next start."

        let (readOnlyVC, _) = makeDisplayController(isReadOnly: true)
        #expect(visibleLabel(caption, in: readOnlyVC.view))

        let (editableVC, _) = makeDisplayController(isReadOnly: false)
        #expect(!visibleLabel(caption, in: editableVC.view))
    }

    // MARK: - Helpers (view-tree introspection)

    private func firstSwitch(action name: String, in view: NSView) -> NSSwitch? {
        firstSubview(NSSwitch.self, in: view) { $0.action.map(NSStringFromSelector) == name }
    }

    private func lockIcons(in view: NSView) -> [NSImageView] {
        allSubviews(NSImageView.self, in: view) { $0.toolTip == "Locked while the VM is running" }
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

    private func firstPopUp(in view: NSView) -> NSPopUpButton? {
        firstSubview(NSPopUpButton.self, in: view)
    }

    /// The editable field in the grouped-form card row titled `label`.
    private func sizeField(_ label: String, in view: NSView) -> NSTextField? {
        let row = firstSubview(NSStackView.self, in: view) { stack in
            stack.arrangedSubviews.contains { ($0 as? NSTextField)?.stringValue == label }
        }
        return row?.arrangedSubviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }
    }
}
