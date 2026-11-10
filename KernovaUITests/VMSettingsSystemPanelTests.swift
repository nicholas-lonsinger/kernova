import AVFoundation
import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// The System panel's own behavior, drilled into through the shell.
@Suite("VM Settings System Panel Tests", .serialized, .caseScoped, .scopedWindows)
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
        phase: VMLifecyclePhase = .stopped,
        isReadOnly: Bool = false,
        sizesToWindow: Bool = false,
        width: Int = 1920,
        height: Int = 1200,
        ppi: Int = 144,
        hiDPI: Bool? = nil,
        holdsSavedState: Bool = false
    ) -> (VMSettingsViewController, VMInstance) {
        let viewModel = makeViewModel()
        let instance = viewModel.library.registerFixture(guestOS: guestOS, phase: phase) {
            $0.displayWidth = width
            $0.displayHeight = height
            $0.displayPPI = ppi
            $0.displaySizesToWindow = sizesToWindow
            $0.displayHiDPI = hiDPI ?? DisplayBootSizing.isHiDPI(ppi: ppi)
        }
        if holdsSavedState { try? VMInstanceFixture.writeSaveFile(for: instance) }
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.system)
        return (vc, instance)
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

    @Test("A typed small size is taken as typed, a 0 clamps to 1, and the popup flips to Custom")
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

        #expect(instance.configuration.displayWidth == 640)
        #expect(instance.configuration.displayHeight == 401)
        #expect(popUp.titleOfSelectedItem == "Custom")

        typeText("0", into: width)
        commitEdit(width)

        #expect(instance.configuration.displayWidth == DisplayBootSizing.minimumDimension)
        #expect(width.integerValue == DisplayBootSizing.minimumDimension)
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

    // MARK: - Input section

    /// Builds a controller over a stock config for `guestOS`.
    private func makeInputController(
        guestOS: VMGuestOS = .macOS, isReadOnly: Bool = false
    ) -> (VMSettingsViewController, VMInstance) {
        makeDisplayController(guestOS: guestOS, isReadOnly: isReadOnly)
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

    @Test("The banner's Open System Settings button opens the Microphone privacy pane")
    func deniedMicBannerButtonOpensSettings() throws {
        let recorder = URLOpenRecorder(results: [true])
        let vc = makeMicController(.denied, systemSettings: SystemSettingsLink(open: recorder.open))

        let button = try #require(findButton(titled: "Open System Settings", in: vc.view))
        button.performClick(nil)

        #expect(recorder.opened == [SystemSettingsLink.microphonePrivacyURL])
    }

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
            storageService: storage,
            diskImageService: MockDiskImageService(),
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: VirtualizationHost(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            localImageInspector: LocalRestoreImageInspector(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            bridgedInterfaces: HostBridgedInterfaceProvider(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: makeTestDownloadsDirectory(),
            preferences: preferences,
            vmnetNetworks: VmnetNetworkService.scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(), bundleProducts: .testing)
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
            typeText(TypedField.cpus.changedValue(from: config), into: field)
        case .memoryField:
            let field = try #require(editableField("Memory", in: vc.view))
            typeText(TypedField.memory.changedValue(from: config), into: field)
        case .widthField:
            let field = try #require(editableField("Width", in: vc.view))
            typeText(TypedField.width.changedValue(from: config), into: field)
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
            return try #require(editableField("Memory", in: vc.view)).stringValue
                == config.memorySizeInGB.gibibytesText
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
        try expectRefusedAfterPinning(edit) { instance in
            // The saved state is what pins the machine.
            try VMInstanceFixture.writeSaveFile(for: instance)
        }
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

        /// The text of a value the VM does not hold, within the field's range.
        func changedValue(from config: VMConfiguration) -> String {
            switch self {
            case .cpus:
                String(
                    config.cpuCount == VirtualizationHost.frameworkResourceLimits.cpuCount.lower
                        ? config.cpuCount + 1 : config.cpuCount - 1)
            case .memory:
                VirtualizationHost.frameworkResourceLimits.memorySize.contains(
                    config.memorySizeInGB.adding(gibibytes: 1))
                    ? config.memorySizeInGB.adding(gibibytes: 1).gibibytesText
                    : config.memorySizeInGB.nextWholeGibibyte(upward: false).gibibytesText
            case .width: String(config.displayBaseSize.width == 1440 ? 1680 : 1440)
            case .height: String(config.displayBaseSize.height == 900 ? 1050 : 900)
            }
        }

        /// The text the field shows for what the VM holds.
        func modelValue(of config: VMConfiguration) -> String {
            switch self {
            case .cpus: String(config.cpuCount)
            case .memory: config.memorySizeInGB.gibibytesText
            case .width: String(config.displayBaseSize.width)
            case .height: String(config.displayBaseSize.height)
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
        let text = typed.changedValue(from: before)
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
        #expect(field.stringValue == typed.modelValue(of: instance.configuration))
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
        let changed = focused.changedValue(from: instance.configuration)

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
        editor.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.stringValue == typed)
        #expect(window.makeFirstResponder(nil))

        #expect(String(instance.configuration.cpuCount) == typed)
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
        typeText(typed, into: field)

        // A click that lands on the value the VM already holds, so a typed
        // edit that survived the click would still show here and be written
        // below.
        stepper.integerValue = original
        stepper.sendAction(stepper.action, to: stepper.target)

        #expect(field.stringValue == String(original))
        #expect(window.makeFirstResponder(nil))
        #expect(instance.configuration.cpuCount == original)
        #expect(presenter.errors.isEmpty)
    }

    @Test("Memory takes a typed decimal to the nearest megabyte, and its arrows move between whole gigabytes")
    func memoryTakesDecimalsAndStepsWhole() throws {
        let (vc, instance, presenter, _) = makeMachineEditController()
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let field = try #require(editableField("Memory", in: vc.view))
        let stepper = try #require(
            allSubviews(NSStepper.self, in: vc.view) {
                $0.action.map(NSStringFromSelector) == "memoryStepperChanged"
            }.first)
        #expect(window.makeFirstResponder(field))
        typeText("1.5", into: field)
        commitEdit(field)
        #expect(instance.configuration.memorySizeInGB.mebibytes == 1536)
        #expect(field.stringValue == "1.5")

        stepper.doubleValue = 2.5  // an up-arrow click from 1.5
        stepper.sendAction(stepper.action, to: stepper.target)
        #expect(instance.configuration.memorySizeInGB == .gibibytes(2))
        #expect(field.stringValue == "2")
        #expect(stepper.doubleValue == 2)
        #expect(presenter.errors.isEmpty)
    }

    // MARK: - Sized-at-last-start note

    private var sizedNote: String { VMSettingsSystemPanelViewController.displayNextColdStartNote }

    /// A save file makes the next start a resume at the saved size, so the
    /// note names a cold start only where the next start is one.
    @Test("The next-cold-start note shows for a never-started or stopped VM, not a suspended one")
    func sizedNoteOnlyWhileTheNextStartIsCold() throws {
        let (neverStarted, fresh) = makeDisplayController(sizesToWindow: true)
        #expect(!fresh.hasSaveFile)
        #expect(visibleLabel(sizedNote, in: neverStarted.view))

        let (stopped, _) = makeDisplayController(
            sizesToWindow: true, width: 2560, height: 1600, ppi: 220)
        #expect(visibleLabel(sizedNote, in: stopped.view))

        let (suspended, saved) = makeDisplayController(
            phase: .suspended, isReadOnly: true, sizesToWindow: true, holdsSavedState: true)
        #expect(saved.hasSaveFile)
        #expect(!visibleLabel(sizedNote, in: suspended.view))
    }

    @Test("The reveal button comes back after a disappearance cancels its probe")
    func serialLogProbeReRunsAfterTheProbeIsCancelled() async throws {
        let instance = VMInstanceFixture.make()
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
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
