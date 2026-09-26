import AVFoundation
import AppKit
import KernovaKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import Kernova

/// The System panel's own behavior, drilled into through the shell.
@Suite("VM Settings System Panel Tests", .serialized, .admissionGated, .scopedWindows)
@MainActor
struct VMSettingsSystemPanelTests {
    private let preferences = makeTestPreferences()

    private func makeViewModel() -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences)
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
        let instance = viewModel.library.registerFixture(guestOS: guestOS) {
            $0.displayWidth = width
            $0.displayHeight = height
            $0.displayPPI = ppi
            $0.displaySizesToWindow = sizesToWindow
            $0.displayHiDPI = hiDPI ?? DisplayBootSizing.isHiDPI(ppi: ppi)
        }
        let vc = makeSettingsPane(
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
        typeText("640", into: width)
        typeText("401", into: height)
        commitEdit(width)

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
        #expect(width.currentEditor() != nil)
        typeText("1600", into: width)

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

    // MARK: - Input section

    /// Builds a controller over a stock config for `guestOS`.
    private func makeInputController(
        guestOS: VMGuestOS = .macOS, isReadOnly: Bool = false
    ) -> (VMSettingsViewController, VMInstance) {
        makeDisplayController(guestOS: guestOS, isReadOnly: isReadOnly)
    }

    @Test("The system keys row is present for both guest OSes, the devices row is macOS-only")
    func systemKeysRowIsNotMacOSOnly() {
        for guestOS in [VMGuestOS.macOS, .linux] {
            let (vc, _) = makeInputController(guestOS: guestOS)
            #expect(containsLabel("Input", in: vc.view))
            #expect(containsLabel("Send system keys to guest", in: vc.view))
            #expect(firstPopUp(action: "systemKeysChanged", in: vc.view) != nil)
            // Linux guests always take the USB pair, so they get no picker.
            #expect(containsLabel("Devices", in: vc.view) == (guestOS == .macOS))
        }
    }

    @Test("The system keys popup opens on the VM's stored mode")
    func systemKeysPopUpShowsStoredMode() {
        let (vc, instance) = makeInputController()
        guard let popUp = firstPopUp(action: "systemKeysChanged", in: vc.view) else {
            Issue.record("Expected the system keys popup")
            return
        }
        #expect(instance.configuration.systemKeyForwarding == .always)
        #expect(popUp.titleOfSelectedItem == "Always")
    }

    @Test("Choosing a system keys mode writes it")
    func systemKeysSelectionWrites() {
        let (vc, instance) = makeInputController()
        guard let popUp = firstPopUp(action: "systemKeysChanged", in: vc.view) else {
            Issue.record("Expected the system keys popup")
            return
        }
        for (title, mode) in [
            ("In Full Screen", VMSystemKeyForwarding.fullscreenOnly), ("Never", .never),
            ("Always", .always),
        ] {
            popUp.selectItem(withTitle: title)
            popUp.sendAction(popUp.action, to: popUp.target)
            #expect(instance.configuration.systemKeyForwarding == mode, "\(title)")
        }
    }

    @Test("A running VM can still change system keys while the devices picker locks")
    func systemKeysStayEditableWhileReadOnly() {
        let (vc, _) = makeInputController(isReadOnly: true)

        #expect(firstPopUp(action: "systemKeysChanged", in: vc.view)?.isEnabled == true)
        #expect(firstPopUp(action: "inputDevicesChanged", in: vc.view)?.isEnabled == false)
    }

    // MARK: - Microphone permission

    /// Builds a controller whose Audio section is driven by a pinned permission
    /// status, so the denied banner does not depend on the test host's own TCC
    /// state.
    private func makeMicController(
        _ status: AVAuthorizationStatus,
        systemSettings: SystemSettingsLink = SystemSettingsLink()
    ) -> VMSettingsViewController {
        let instance = makeSettingsInstance(guestOS: .linux) { $0.audioInputEnabled = true }
        let vc = makeSettingsPane(
            instance: instance, viewModel: makeViewModel(), isReadOnly: false,
            micPermissionStatus: { status }, systemSettings: systemSettings)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.system)
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

    // MARK: - Serial console

    // MARK: - Edits committed after the machine is pinned

    /// A control the System panel writes a machine setting from — one the VM's
    /// running session or saved state pins.
    enum MachineEdit: String, CaseIterable, Sendable {
        case cpuField, memoryField, widthField, matchWindowSwitch, hiDPISwitch, audioInput,
            audioOutput, inputDevices

        /// The key the edit writes, which a refusal names.
        var key: String {
            switch self {
            case .cpuField: "cpus"
            case .memoryField: "memory"
            case .widthField: "display.width"
            case .matchWindowSwitch: "display.sizeToWindow"
            case .hiDPISwitch: "display.hidpi"
            case .audioInput: "audio.input"
            case .audioOutput: "audio.output"
            case .inputDevices: "input.devices"
            }
        }
    }

    /// A stopped, registered macOS VM in a pane open on System that is not
    /// read-only, booting at `resolution` in manual mode, with a presenter
    /// recording what the refusal shows.
    private func makeMachineEditController(
        resolution: DisplayBootSizing.Resolution = DisplayBootSizing.Resolution(
            width: 1920, height: 1200, ppi: DisplayBootSizing.standardPixelsPerInch)
    ) -> (
        VMSettingsViewController, VMInstance, MockVMLibraryPresenting, MockVMStorageService
    ) {
        let presenter = MockVMLibraryPresenting()
        let storage = MockVMStorageService()
        let viewModel = VMLibraryViewModel(
            storageService: storage, diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(), ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(), downloadsDirectory: nil, preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(),
            entitlements: .entitled)
        viewModel.presenter = presenter
        let instance = viewModel.library.registerFixture(guestOS: .macOS) {
            $0.displayResolution = resolution
            $0.displaySizesToWindow = false
            $0.displayHiDPI = DisplayBootSizing.isHiDPI(ppi: resolution.ppi)
        }
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.system)
        return (vc, instance, presenter, storage)
    }

    /// Moves `edit`'s control off the value the model holds, as a user would,
    /// without committing it.
    private func change(_ edit: MachineEdit, in vc: VMSettingsViewController, _ config: VMConfiguration)
        throws
    {
        switch edit {
        case .cpuField:
            let field = try #require(editableField("CPU cores", in: vc.view))
            typeText(String(TypedField.cpus.changedValue(from: config)), into: field)
        case .memoryField:
            let field = try #require(editableField("Memory", in: vc.view))
            typeText(String(TypedField.memory.changedValue(from: config)), into: field)
        case .widthField:
            let field = try #require(editableField("Width", in: vc.view))
            typeText(String(TypedField.width.changedValue(from: config)), into: field)
        case .matchWindowSwitch, .hiDPISwitch, .audioInput, .audioOutput:
            let toggle = try #require(firstSwitch(action: switchAction(edit), in: vc.view))
            toggle.state = toggle.state == .on ? .off : .on
        case .inputDevices:
            let popUp = try #require(firstPopUp(action: "inputDevicesChanged", in: vc.view))
            let other = try #require(
                popUp.itemArray.firstIndex {
                    ($0.representedObject as? VMInputDeviceMode) != config.inputDeviceMode
                })
            popUp.selectItem(at: other)
        }
    }

    private func switchAction(_ edit: MachineEdit) -> String {
        switch edit {
        case .matchWindowSwitch: "displayMatchWindowToggled"
        case .hiDPISwitch: "displayHiDPIToggled"
        case .audioInput: "audioInputToggled"
        case .audioOutput: "audioOutputToggled"
        case .cpuField, .memoryField, .widthField, .inputDevices: ""
        }
    }

    /// Commits `edit`'s control the way AppKit does: a field's end-edit, a
    /// switch's or popup's action.
    private func commit(_ edit: MachineEdit, in vc: VMSettingsViewController) throws {
        switch edit {
        case .cpuField: commitEdit(try #require(editableField("CPU cores", in: vc.view)))
        case .memoryField: commitEdit(try #require(editableField("Memory", in: vc.view)))
        case .widthField: commitEdit(try #require(editableField("Width", in: vc.view)))
        case .matchWindowSwitch, .hiDPISwitch, .audioInput, .audioOutput:
            let toggle = try #require(firstSwitch(action: switchAction(edit), in: vc.view))
            toggle.sendAction(toggle.action, to: toggle.target)
        case .inputDevices:
            let popUp = try #require(firstPopUp(action: "inputDevicesChanged", in: vc.view))
            popUp.sendAction(popUp.action, to: popUp.target)
        }
    }

    /// Whether `edit`'s control shows the value `config` holds.
    private func showsModel(
        _ edit: MachineEdit, in vc: VMSettingsViewController, _ config: VMConfiguration
    ) throws -> Bool {
        switch edit {
        case .cpuField:
            return try #require(editableField("CPU cores", in: vc.view)).integerValue
                == config.cpuCount
        case .memoryField:
            return try #require(editableField("Memory", in: vc.view)).integerValue
                == config.memorySizeInGB
        case .widthField:
            return try #require(editableField("Width", in: vc.view)).integerValue
                == config.displayBaseSize.width
        case .matchWindowSwitch:
            return try #require(firstSwitch(action: switchAction(edit), in: vc.view)).state
                == (config.displaySizesToWindow ? .on : .off)
        case .hiDPISwitch:
            return try #require(firstSwitch(action: switchAction(edit), in: vc.view)).state
                == (config.displayHiDPI ? .on : .off)
        case .audioInput:
            return try #require(firstSwitch(action: switchAction(edit), in: vc.view)).state
                == (config.audioInputEnabled ? .on : .off)
        case .audioOutput:
            return try #require(firstSwitch(action: switchAction(edit), in: vc.view)).state
                == (config.audioOutputEnabled ? .on : .off)
        case .inputDevices:
            let popUp = try #require(firstPopUp(action: "inputDevicesChanged", in: vc.view))
            return (popUp.selectedItem?.representedObject as? VMInputDeviceMode)
                == config.inputDeviceMode
        }
    }

    /// Changes `edit`'s control on a VM at rest, pins the machine with `pin`,
    /// then commits — the order a pane left open while the CLI starts or
    /// suspends the VM produces.
    private func expectRefusedAfterPinning(
        _ edit: MachineEdit, pin: (VMInstance) throws -> Void
    ) throws {
        let (vc, instance, presenter, storage) = makeMachineEditController()
        let before = instance.configuration
        let onDisk = storage.bundles[instance.bundleURL]
        try change(edit, in: vc, before)

        try pin(instance)
        try commit(edit, in: vc)

        #expect(instance.configuration == before)
        #expect(storage.bundles[instance.bundleURL] == onDisk)
        #expect(presenter.errors.count == 1)
        #expect(presenter.errors.first?.contains(edit.key) == true)
        #expect(try showsModel(edit, in: vc, instance.configuration))
    }

    @Test(
        "A machine edit committed after the VM started is refused and changes nothing",
        arguments: MachineEdit.allCases)
    func machineEditCommittedAfterAStartIsRefused(_ edit: MachineEdit) throws {
        try expectRefusedAfterPinning(edit) { $0.activity.placeForTesting(.running(sessionID: UUID())) }
    }

    @Test(
        "A machine edit committed after the VM suspended is refused and changes nothing",
        arguments: MachineEdit.allCases)
    func machineEditCommittedAfterASuspendIsRefused(_ edit: MachineEdit) throws {
        var pinned: VMInstance?
        defer { pinned.map(VMInstanceFixture.removeBundle(of:)) }
        try expectRefusedAfterPinning(edit) { instance in
            pinned = instance
            // The saved state is what pins the machine: resume restores only
            // into the configuration it was suspended from.
            try VMInstanceFixture.writeSaveFile(for: instance)
        }
    }

    /// The boot resolutions an unchanged size field has to write back exactly:
    /// a standard one, and a Retina one whose "looks like" size is odd — the
    /// half of a window-fitted pixel count a start can leave behind.
    nonisolated static let unchangedResolutions = [
        DisplayBootSizing.Resolution(
            width: 1920, height: 1200, ppi: DisplayBootSizing.standardPixelsPerInch),
        DisplayBootSizing.Resolution(
            width: 1602, height: 1202, ppi: DisplayBootSizing.hiDPIPixelsPerInch),
    ]

    @Test(
        "Ending an unchanged edit after the VM started raises nothing and writes nothing",
        arguments: unchangedResolutions)
    func endingAnUnchangedEditAfterAStartRaisesNothing(
        _ resolution: DisplayBootSizing.Resolution
    ) throws {
        let (vc, instance, presenter, storage) = makeMachineEditController(resolution: resolution)
        let before = instance.configuration
        let onDisk = storage.bundles[instance.bundleURL]

        instance.activity.placeForTesting(.running(sessionID: UUID()))
        for label in ["CPU cores", "Memory", "Width", "Height"] {
            commitEdit(try #require(editableField(label, in: vc.view)))
        }

        #expect(presenter.errors.isEmpty)
        #expect(instance.configuration == before)
        #expect(storage.bundles[instance.bundleURL] == onDisk)
    }

    /// Every end-edit field, which a start can catch mid-edit.
    enum TypedField: String, CaseIterable, Sendable {
        case cpus = "CPU cores"
        case memory = "Memory"
        case width = "Width"
        case height = "Height"

        /// The key the field writes, which a refusal names.
        var key: String {
            switch self {
            case .cpus: "cpus"
            case .memory: "memory"
            case .width: "display.width"
            case .height: "display.height"
            }
        }

        /// A value the VM does not hold, within the field's range.
        func changedValue(from config: VMConfiguration) -> Int {
            switch self {
            case .cpus: config.cpuCount == config.guestOS.minCPUCount ? config.cpuCount + 1 : config.cpuCount - 1
            case .memory:
                config.memorySizeInGB == config.guestOS.minMemoryInGB
                    ? config.memorySizeInGB + 1 : config.memorySizeInGB - 1
            case .width: config.displayBaseSize.width == 1440 ? 1680 : 1440
            case .height: config.displayBaseSize.height == 900 ? 1050 : 900
            }
        }

        /// What the VM holds for the field.
        func modelValue(of config: VMConfiguration) -> Int {
            switch self {
            case .cpus: config.cpuCount
            case .memory: config.memorySizeInGB
            case .width: config.displayBaseSize.width
            case .height: config.displayBaseSize.height
            }
        }
    }

    @Test(
        "Text typed before a start survives the refresh the start makes, and its end-edit is refused",
        arguments: TypedField.allCases)
    func aTypedEditSurvivesTheStartsRefreshAndIsRefused(_ typed: TypedField) throws {
        let (vc, instance, presenter, storage) = makeMachineEditController()
        let before = instance.configuration
        let onDisk = storage.bundles[instance.bundleURL]
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField(typed.rawValue, in: vc.view))
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil)
        let text = String(typed.changedValue(from: before))
        typeText(text, into: field)

        instance.activity.placeForTesting(.running(sessionID: UUID()))
        // Stands in for the observation pass the status change drives.
        vc.viewDidAppear()
        #expect(field.currentEditor()?.string == text)
        commitEdit(field)

        #expect(presenter.errors.count == 1)
        #expect(presenter.errors.first?.contains(typed.key) == true)
        #expect(instance.configuration == before)
        #expect(storage.bundles[instance.bundleURL] == onDisk)
        #expect(field.integerValue == typed.modelValue(of: instance.configuration))
    }

    @Test(
        "A focused field nobody typed in follows a model change and writes nothing when focus leaves",
        arguments: TypedField.allCases)
    func aFocusedUntypedFieldFollowsTheModel(_ focused: TypedField) throws {
        let (vc, instance, presenter, _) = makeMachineEditController()
        let viewModel = try #require(vc.settingsPanelForTesting(.system)).viewModel
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField(focused.rawValue, in: vc.view))
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil)
        let changed = String(focused.changedValue(from: instance.configuration))

        // Not the pane's own write: the field hears of it only through the
        // model, as it does a CLI `set`.
        let outcome = viewModel.setConfiguration(
            [ConfigurationEntry(key: focused.key, value: changed)], on: instance)
        #expect(outcome == .applied)
        // Stands in for the observation pass the write drives.
        vc.viewDidAppear()
        #expect(field.currentEditor()?.string == changed)
        let after = instance.configuration
        #expect(window.makeFirstResponder(nil))

        #expect(instance.configuration == after)
        #expect(presenter.errors.isEmpty)
        #expect(field.stringValue == changed)
    }

    @Test("A count committed with Return is not written back over a later CLI set")
    func aCommittedCountLeavesALaterSetStanding() throws {
        let (vc, instance, presenter, _) = makeMachineEditController()
        let viewModel = try #require(vc.settingsPanelForTesting(.system)).viewModel
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("CPU cores", in: vc.view))
        let original = instance.configuration.cpuCount
        let typed = TypedField.cpus.changedValue(from: instance.configuration)
        #expect(window.makeFirstResponder(field))
        typeText(String(typed), into: field)

        // Return commits the edit and leaves the field focused, its text
        // reselected in a field editor.
        try #require(field.currentEditor() as? NSTextView).insertNewline(nil)
        #expect(instance.configuration.cpuCount == typed)
        if field.currentEditor() == nil { #expect(window.makeFirstResponder(field)) }

        let outcome = viewModel.setConfiguration(
            [ConfigurationEntry(key: "cpus", value: String(original))], on: instance)
        #expect(outcome == .applied)
        // Stands in for the observation pass the write drives.
        vc.viewDidAppear()
        #expect(field.currentEditor()?.string == String(original))
        // Clicking the sidebar ends the edit.
        #expect(window.makeFirstResponder(nil))

        #expect(instance.configuration.cpuCount == original)
        #expect(presenter.errors.isEmpty)
    }

    @Test("A refresh that changes nothing keeps a focused field's selection, so a keystroke replaces its value")
    func aSameValueRefreshKeepsTheTabInSelection() throws {
        let (vc, instance, presenter, _) = makeMachineEditController()
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("CPU cores", in: vc.view))
        let shown = field.stringValue
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: 0, length: shown.utf16.count))

        // Another control's write, and the refresh it drives.
        let toggle = try #require(firstSwitch(action: "audioOutputToggled", in: vc.view))
        toggle.state = toggle.state == .on ? .off : .on
        toggle.sendAction(toggle.action, to: toggle.target)
        vc.viewDidAppear()

        #expect(editor.selectedRange() == NSRange(location: 0, length: shown.utf16.count))
        let typed = TypedField.cpus.changedValue(from: instance.configuration)
        editor.insertText(String(typed), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.stringValue == String(typed))
        #expect(window.makeFirstResponder(nil))

        #expect(instance.configuration.cpuCount == typed)
        #expect(presenter.errors.isEmpty)
    }

    @Test("A stepper click replaces typed text, and focus leaving writes nothing more")
    func aStepperClickReplacesATypedEdit() throws {
        let (vc, instance, presenter, _) = makeMachineEditController()
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("CPU cores", in: vc.view))
        let stepper = try #require(
            allSubviews(NSStepper.self, in: vc.view) {
                $0.action.map(NSStringFromSelector) == "cpuStepperChanged"
            }.first)
        let original = instance.configuration.cpuCount
        let typed = TypedField.cpus.changedValue(from: instance.configuration)
        #expect(window.makeFirstResponder(field))
        typeText(String(typed), into: field)

        // A click that lands on the value the VM already holds: the guest's
        // count range can be as narrow as two values, and a typed edit that
        // survived the click would still show here and be written below.
        stepper.integerValue = original
        stepper.sendAction(stepper.action, to: stepper.target)

        #expect(field.stringValue == String(original))
        #expect(window.makeFirstResponder(nil))
        #expect(instance.configuration.cpuCount == original)
        #expect(presenter.errors.isEmpty)
    }

    @Test("Typing back the value a CLI set replaced is an edit, and is written")
    func typingTheReplacedValueBackIsWritten() throws {
        let (vc, instance, presenter, _) = makeMachineEditController()
        let viewModel = try #require(vc.settingsPanelForTesting(.system)).viewModel
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("CPU cores", in: vc.view))
        let original = instance.configuration.cpuCount
        let changed = String(TypedField.cpus.changedValue(from: instance.configuration))
        #expect(window.makeFirstResponder(field))

        let outcome = viewModel.setConfiguration(
            [ConfigurationEntry(key: "cpus", value: changed)], on: instance)
        #expect(outcome == .applied)
        // Stands in for the observation pass the write drives.
        vc.viewDidAppear()
        #expect(field.currentEditor()?.string == changed)
        typeText(String(original), into: field)
        #expect(window.makeFirstResponder(nil))

        #expect(instance.configuration.cpuCount == original)
        #expect(presenter.errors.isEmpty)
    }

    // MARK: - Resolution caption

    private func resolutionCaption(in vc: VMSettingsViewController) -> String? {
        allSubviews(NSTextField.self, in: vc.view) { $0.stringValue.hasPrefix("Boots at") }
            .first?.stringValue
    }

    private func toggleHiDPI(_ isOn: Bool, in vc: VMSettingsViewController) throws {
        let hiDPI = try #require(firstSwitch(action: "displayHiDPIToggled", in: vc.view))
        hiDPI.state = isOn ? .on : .off
        hiDPI.sendAction(hiDPI.action, to: hiDPI.target)
    }

    @Test("The resolution caption follows HiDPI off, then on")
    func resolutionCaptionFollowsHiDPI() throws {
        let (vc, _) = makeDisplayController(width: 1600, height: 1800, ppi: 220)

        try toggleHiDPI(false, in: vc)
        #expect(resolutionCaption(in: vc) == "Boots at 800 × 900 pixels.")

        try toggleHiDPI(true, in: vc)
        #expect(resolutionCaption(in: vc) == "Boots at 1600 × 1800 pixels (looks like 800 × 900).")
    }

    @Test("In match mode the caption names the HiDPI change the next start applies")
    func matchModeCaptionNamesThePendingDensity() throws {
        let (vc, _) = makeDisplayController(
            sizesToWindow: true, width: 1600, height: 1800, ppi: 220)

        try toggleHiDPI(false, in: vc)
        #expect(
            resolutionCaption(in: vc)
                == "Boots at 1600 × 1800 pixels (looks like 800 × 900), until the next start "
                + "resizes it to the window without HiDPI.")

        try toggleHiDPI(true, in: vc)
        #expect(
            resolutionCaption(in: vc)
                == "Boots at 1600 × 1800 pixels (looks like 800 × 900), until the next start "
                + "resizes it to the window.")
    }

    @Test("In match mode the caption promises HiDPI only on a Retina display")
    func matchModeCaptionQualifiesThePendingHiDPI() throws {
        let (vc, _) = makeDisplayController(
            sizesToWindow: true, width: 1600, height: 1800, ppi: 144)

        try toggleHiDPI(true, in: vc)
        #expect(
            resolutionCaption(in: vc)
                == "Boots at 1600 × 1800 pixels, until the next start resizes it to the window, "
                + "with HiDPI on a Retina display.")
    }

    @Test("The resolution caption follows a HiDPI write made through the verb")
    func resolutionCaptionFollowsAVerbWrite() throws {
        let (vc, instance) = makeDisplayController(width: 1600, height: 1800, ppi: 220)
        let viewModel = try #require(vc.settingsPanelForTesting(.system)).viewModel

        // Not the pane's own write: the caption hears of it only through the
        // model, as it does a CLI `set`.
        let outcome = viewModel.setConfiguration(
            [VMConfigurationKeyRegistry.displayHiDPI.assigning(false)], on: instance)
        #expect(outcome == .applied)

        // Stands in for the observation pass the write drives.
        vc.viewDidAppear()
        #expect(resolutionCaption(in: vc) == "Boots at 800 × 900 pixels.")
    }

    @Test("A refused end-edit puts the model's value back in a field whose editor is still attached")
    func refusedEndEditRevertsAFieldStillBeingEdited() throws {
        let (vc, instance, presenter, _) = makeMachineEditController()
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let width = try #require(editableField("Width", in: vc.view))
        #expect(window.makeFirstResponder(width))
        #expect(width.currentEditor() != nil)
        typeText("1440", into: width)

        instance.activity.placeForTesting(.running(sessionID: UUID()))
        commitEdit(width)

        #expect(presenter.errors.count == 1)
        #expect(width.integerValue == instance.configuration.displayBaseSize.width)
    }
    @Test("The reveal button comes back after a disappearance cancels its probe")
    func serialLogProbeReRunsAfterTheProbeIsCancelled() async throws {
        let instance = VMInstanceFixture.make()
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        let viewModel = makeViewModel()
        FileManager.default.createFile(
            atPath: instance.serialLogURL.path(percentEncoded: false), contents: Data([0]))
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.system)

        let panel = try #require(
            vc.settingsPanelForTesting(.system) as? VMSettingsSystemPanelViewController)
        let reveal = try #require(findButton(titled: "Reveal serial.log in Finder", in: vc.view))
        // The probe is still out, so the button has yet to be answered for.
        #expect(!reveal.isEnabled)

        // The pane goes away before it lands, cancelling it — coming back has to
        // re-run it, or the button stays dead until the VM's state moves.
        vc.viewWillDisappear()
        vc.viewDidAppear()
        await panel.serialLogProbeForTesting?.value

        #expect(reveal.isEnabled)
    }
}
