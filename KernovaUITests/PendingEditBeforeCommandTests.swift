import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// A settings edit still open in its field when a command is asked for — a
/// toolbar button, a menu item or a key equivalent, none of which takes focus
/// from the field.
@Suite("Pending edits before a command", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct PendingEditBeforeCommandTests {
    typealias TypedField = VMSettingsSystemPanelTests.TypedField

    private let preferences = makeTestPreferences()

    private struct Fixture {
        let pane: VMSettingsViewController
        let window: NSWindow
        let instance: VMInstance
        let viewModel: VMLibraryViewModel
        let registry: AppWindowRegistry
        let presenter: MockVMLibraryPresenting
        let virtualization: MockVirtualizationService
    }

    /// A stopped VM's settings pane open on System in a window, over a view
    /// model wired as the app wires it to save pending edits.
    private func makeFixture() -> Fixture {
        let presenter = MockVMLibraryPresenting()
        let storage = MockVMStorageService()
        let virtualization = MockVirtualizationService()
        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: VirtualizationHost(),
            virtualizationService: virtualization,
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
        let registry = makeWindowRegistry(viewModel)
        viewModel.savePendingEdits = { [weak registry] in registry?.savePendingEdits() }
        let instance = viewModel.library.registerFixture(guestOS: .linux) {
            $0.displaySizesToWindow = false
        }
        let pane = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
        pane.loadViewIfNeeded()
        pane.viewDidAppear()
        pane.showCategory(.system)
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = pane.view
        return Fixture(
            pane: pane, window: window, instance: instance, viewModel: viewModel, registry: registry,
            presenter: presenter, virtualization: virtualization)
    }

    /// Types a value the VM does not hold into `field`, leaving the edit open.
    private func typeChange(
        _ field: TypedField, in fixture: Fixture
    ) throws -> (control: NSTextField, text: String) {
        let control = try #require(editableField(field.rawValue, in: fixture.pane.view))
        let text = field.changedValue(from: fixture.instance.configuration)
        typeText(text, into: control)
        try #require(control.currentEditor()?.string == text)
        return (control, text)
    }

    @Test(
        "Start saves an edit still open in a field before the start reads the configuration",
        arguments: TypedField.allCases)
    func startSavesThePendingEditFirst(_ field: TypedField) async throws {
        let fixture = makeFixture()
        let (control, text) = try typeChange(field, in: fixture)

        await fixture.viewModel.start(fixture.instance)

        #expect(fixture.instance.status == .running)
        let booted = try #require(fixture.virtualization.configurationAtStart)
        #expect(field.modelValue(of: booted) == text)
        #expect(field.modelValue(of: fixture.instance.configuration) == text)
        #expect(control.stringValue == text)
        // The pane going away is what used to commit the edit, after the start
        // held the VM.
        fixture.window.contentView = nil
        #expect(fixture.presenter.errors.isEmpty)
    }

    @Test("Clone saves an edit still open in a field before the clone copies the configuration")
    func cloneSavesThePendingEditFirst() async throws {
        let fixture = makeFixture()
        let (control, text) = try typeChange(.cpus, in: fixture)

        fixture.viewModel.cloneVM(fixture.instance)

        #expect(TypedField.cpus.modelValue(of: fixture.instance.configuration) == text)
        #expect(control.currentEditor() == nil)
        try await waitForChange { fixture.viewModel.instances.count == 2 }
        let clone = try #require(fixture.viewModel.instances.last)
        #expect(clone !== fixture.instance)
        #expect(TypedField.cpus.modelValue(of: clone.configuration) == text)
        #expect(fixture.presenter.errors.isEmpty)
    }
}
