import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// The Reminders settings pane's switches, and the preference each one saves.
@Suite("Reminders Settings Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct RemindersSettingsViewControllerTests {
    private let preferences: AppPreferences

    init() {
        self.preferences = makeTestPreferences()
    }

    private func makeViewModel(
        virtualization: MockVirtualizationService = MockVirtualizationService()
    ) -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
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
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
        )
    }

    /// As ``makeLaidOutController(vmCount:)``, also handing back the view model
    /// so a test can drive the app-wide install-prompt preference.
    private func makeLaidOutPane(vmCount: Int) -> (
        controller: RemindersSettingsViewController, viewModel: VMLibraryViewModel
    ) {
        let viewModel = makeViewModel()
        for index in 1...vmCount {
            viewModel.library.admitFixture(name: "VM \(index)", guestOS: .macOS)
        }
        let controller = RemindersSettingsViewController(viewModel: viewModel, visibleFrame: offDesktopVisibleFrame)
        _ = controller.view
        controller.refreshContent()
        controller.viewWillAppear()
        controller.view.setFrameSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, viewModel)
    }

    /// Every switch in the pane wired to `action`, in row order.
    private func switches(action name: String, in controller: RemindersSettingsViewController)
        -> [NSSwitch]
    {
        allSubviews(NSSwitch.self, in: controller.view) {
            $0.action.map(NSStringFromSelector) == name
        }
    }

    // MARK: - The duplicate machine ID question

    private func questionSwitch(in controller: RemindersSettingsViewController) throws -> NSSwitch {
        try #require(switches(action: "duplicateIDQuestionToggled", in: controller).first)
    }

    /// Flips the duplicate machine ID question's switch the way a click does,
    /// so the pane's own action wiring is what drives the change.
    private func setQuestion(on: Bool, in controller: RemindersSettingsViewController) throws {
        let toggle = try questionSwitch(in: controller)
        toggle.state = on ? .on : .off
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
    }

    @Test("Turning the question's switch off saves the choice not to be asked, and on clears it")
    func theQuestionsSwitchWorksBothWays() throws {
        preferences.allowsDuplicateMachineIDOverride = true
        let (controller, viewModel) = makeLaidOutPane(vmCount: 1)
        defer { controller.viewDidDisappear() }
        let toggle = try questionSwitch(in: controller)
        #expect(toggle.state == .on)
        #expect(toggle.isEnabled)

        try setQuestion(on: false, in: controller)

        #expect(viewModel.duplicateMachineIDQuestionDismissed)
        #expect(preferences.duplicateMachineIDQuestionDismissed)
        #expect(toggle.isEnabled)

        try setQuestion(on: true, in: controller)

        #expect(viewModel.duplicateMachineIDQuestionDismissed == false)
        #expect(preferences.duplicateMachineIDQuestionDismissed == false)
        #expect(toggle.isEnabled)
    }

    @Test("The Ephemeral banner's switch follows the view model both ways, and reset turns it back on")
    func ephemeralBannerSwitchWorksBothWays() throws {
        let (controller, viewModel) = makeLaidOutPane(vmCount: 1)
        defer { controller.viewDidDisappear() }
        let toggle = try #require(switches(action: "ephemeralSettingsBannerToggled", in: controller).first)
        #expect(toggle.state == .on)

        toggle.state = .off
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
        #expect(viewModel.ephemeralSettingsBannerDismissed)
        #expect(preferences.ephemeralSettingsBannerDismissed)

        let reset = try #require(
            allSubviews(NSButton.self, in: controller.view) { $0.title == "Reset All Reminders" }.first)
        #expect(NSApp.sendAction(try #require(reset.action), to: reset.target, from: reset))
        #expect(viewModel.ephemeralSettingsBannerDismissed == false)
        #expect(toggle.state == .on)
    }
}
