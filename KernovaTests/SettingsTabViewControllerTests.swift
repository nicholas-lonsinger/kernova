import AppKit
import Foundation
import Testing

@testable import Kernova

/// Tests for the Settings window's tab container.
///
/// The container owns what happens *between* panes: sizing the window to the
/// one being selected, and re-arming its "more below" cue so an overflowing
/// pane says so on every arrival rather than only its first.
@Suite("Settings Tab Tests", .serialized)
@MainActor
struct SettingsTabViewControllerTests {
    private let preferences: AppPreferences

    init() {
        self.preferences = makeEphemeralPreferences(suiteName: "test.kernova.settings-tab")
    }

    private func makeViewModel(vmCount: Int) -> VMLibraryViewModel {
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences
        )
        for index in 1...vmCount {
            let config = VMConfiguration(name: "VM \(index)", guestOS: .macOS, bootMode: .efi)
            let bundleURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(config.id.uuidString, isDirectory: true)
            viewModel.instances.append(VMInstance(configuration: config, bundleURL: bundleURL))
        }
        return viewModel
    }

    /// Builds the container plus a laid-out Reminders pane tall enough to
    /// overflow, standing in for the window the tab controller would size.
    private func makeOverflowingPane() throws -> (
        SettingsTabViewController, RemindersSettingsViewController
    ) {
        let tabController = SettingsTabViewController(
            viewModel: makeViewModel(vmCount: 9), preferences: preferences)
        tabController.loadViewIfNeeded()
        let pane = try #require(
            tabController.tabViewItems.compactMap { $0.viewController }
                .compactMap { $0 as? RemindersSettingsViewController }.first)
        pane.loadViewIfNeeded()
        pane.viewWillAppear()
        pane.view.setFrameSize(pane.preferredContentSize)
        pane.view.layoutSubtreeIfNeeded()
        return (tabController, pane)
    }

    private func remindersItem(in tabController: SettingsTabViewController) throws -> NSTabViewItem {
        try #require(
            tabController.tabViewItems.first { $0.viewController is RemindersSettingsViewController })
    }

    @Test("Every selection of an overflowing pane re-arms its scroller flash")
    func selectingOverflowingPaneFlashesEachTime() throws {
        let (tabController, pane) = try makeOverflowingPane()
        defer { pane.viewDidDisappear() }
        let indicator = try #require(pane.scrollMoreIndicatorForTesting)
        let item = try remindersItem(in: tabController)

        // Appearing already flashed once; each later arrival must flash again,
        // which the one-shot latch prevents without the container's re-arm.
        let afterFirstAppearance = indicator.flashCountForTesting
        #expect(afterFirstAppearance == 1)

        tabController.tabView(tabController.tabView, didSelect: item)
        #expect(indicator.flashCountForTesting == afterFirstAppearance + 1)

        tabController.tabView(tabController.tabView, didSelect: item)
        #expect(indicator.flashCountForTesting == afterFirstAppearance + 2)
    }

    /// Reopening the window re-shows whichever pane was last selected without a
    /// tab switch, so the container's own appearance is the only cue hook.
    @Test("The container's appearance re-arms the selected pane")
    func containerAppearanceRearmsSelectedPane() throws {
        let (tabController, pane) = try makeOverflowingPane()
        defer { pane.viewDidDisappear() }
        let indicator = try #require(pane.scrollMoreIndicatorForTesting)
        tabController.tabView.selectTabViewItem(try remindersItem(in: tabController))
        let before = indicator.flashCountForTesting

        tabController.viewWillAppear()

        #expect(indicator.flashCountForTesting == before + 1)
    }

    /// A pane that never overflows publishes no cue, so selecting it must not
    /// reach for one — the container asks only panes that opt in.
    @Test("Selecting a pane without a cue is inert")
    func selectingNonCueingPaneIsInert() throws {
        let (tabController, pane) = try makeOverflowingPane()
        defer { pane.viewDidDisappear() }
        let indicator = try #require(pane.scrollMoreIndicatorForTesting)
        let general = try #require(
            tabController.tabViewItems.first {
                $0.viewController is GeneralSettingsViewController
            })
        let before = indicator.flashCountForTesting

        tabController.tabView(tabController.tabView, didSelect: general)

        #expect(indicator.flashCountForTesting == before)
    }
}
