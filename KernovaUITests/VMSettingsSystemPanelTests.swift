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
