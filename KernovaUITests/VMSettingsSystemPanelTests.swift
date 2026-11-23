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
}
