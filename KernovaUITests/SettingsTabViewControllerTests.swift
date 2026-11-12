import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// Tests for the Settings window's tab container.
///
/// The container owns what happens *between* panes: sizing the window to the
/// one being selected, and re-arming its "more below" cue so an overflowing
/// pane says so on every arrival rather than only its first.
@Suite("Settings Tab Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SettingsTabViewControllerTests {
    private let preferences: AppPreferences

    init() {
        self.preferences = makeTestPreferences()
    }

    private func makeViewModel(vmCount: Int) -> VMLibraryViewModel {
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
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
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
        )
        for index in 1...vmCount {
            viewModel.library.admitFixture(name: "VM \(index)", guestOS: .macOS)
        }
        return viewModel
    }

    /// Builds the container plus a laid-out Reminders pane tall enough to
    /// overflow, standing in for the window the tab controller would size.
    private func makeOverflowingPane() throws -> (
        SettingsTabViewController, RemindersSettingsViewController
    ) {
        let tabController = SettingsTabViewController(
            viewModel: makeViewModel(vmCount: overflowingVMCount()), visibleFrame: offDesktopVisibleFrame)
        tabController.loadViewIfNeeded()
        let item = try remindersItem(in: tabController)
        // Select before hosting: selecting moves the pane's view into the tab
        // view, which has no window here, and the cue only fires against a
        // visible one. Doing it first lets `showInTestWindow` take the view back
        // while the item stays selected, so `viewDidAppear` still targets it.
        tabController.tabView.selectTabViewItem(item)
        let pane = try #require(item.viewController as? RemindersSettingsViewController)
        pane.loadViewIfNeeded()
        // Measure detached first, then give the window that size, standing in for
        // the container's own `resizeWindow(toFit:)`.
        pane.refreshContent()
        pane.viewWillAppear()
        showInTestWindow(pane.view, size: pane.preferredContentSize)
        pane.view.layoutSubtreeIfNeeded()
        // The arrival cue: ordering a window on screen changes no geometry, so
        // nothing re-runs the flash on its own.
        pane.rearmScrollMoreCue()
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
        let before = indicator.flashCountForTesting

        tabController.viewDidAppear()

        #expect(indicator.flashCountForTesting == before + 1)
    }

    // MARK: - Destinations

    private func tabs(of registry: AppWindowRegistry) throws -> SettingsTabViewController {
        let window = try #require(registry.settingsWindow)
        return try #require(window.contentViewController as? SettingsTabViewController)
    }

    private func networksPane(in tabs: SettingsTabViewController) throws -> NetworksSettingsViewController {
        try #require(tabs.tabViewItems.lazy.compactMap { $0.viewController as? NetworksSettingsViewController }.first)
    }

    @Test("Settings opened on a network for the first time shows the Networks pane with its row selected")
    func firstOpenLandsOnTheNetwork() throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        _ = try viewModel.networks.create(name: "Other", kind: .nat, verb: .createNetwork)
        let lab = try viewModel.networks.create(name: "Lab", kind: .hostOnly, verb: .createNetwork)
        let registry = makeWindowRegistry(viewModel)

        registry.showSettings(at: .network(lab.id))

        let tabs = try tabs(of: registry)
        #expect(tabs.selectedPaneForTesting == .networks)
        #expect(try networksPane(in: tabs).selectedNetworkIDForTesting == lab.id)
    }

    /// AppKit fits a window onto its screen as it orders in, so a window still
    /// at a provisional height there moves when its saved top-left puts its
    /// bottom off screen.
    @Test("Settings has its pane's height when it orders in", arguments: [nil, SettingsDestination.pane(.reminders)])
    func settingsHasItsPaneHeightWhenItOrdersIn(destination: SettingsDestination?) throws {
        let focus = RecordingSessionFocus()
        let registry = makeWindowRegistry(makeSettingsViewModel(preferences: preferences), focus: focus)
        var heightAtOrderIn: CGFloat?
        focus.willOrderIn = { window in
            heightAtOrderIn = window.contentRect(forFrameRect: window.frame).height
        }

        registry.showSettings(at: destination)

        let pane = try #require(try tabs(of: registry).tabView.selectedTabViewItem?.viewController)
        #expect(pane.preferredContentSize.height > 0)
        #expect(heightAtOrderIn == pane.preferredContentSize.height)
    }

    @Test("Each pane is a destination, and one the build does not offer leaves the selection")
    func everyOfferedPaneIsADestination() throws {
        let tabController = SettingsTabViewController(
            viewModel: makeSettingsViewModel(preferences: preferences), visibleFrame: offDesktopVisibleFrame)
        for pane in SettingsPane.allCases {
            tabController.show(.pane(pane))
            #expect(tabController.selectedPaneForTesting == pane)
        }

        let unentitled = makeSettingsViewModel(preferences: preferences, entitled: false)
        let limited = SettingsTabViewController(viewModel: unentitled, visibleFrame: offDesktopVisibleFrame)
        limited.show(.pane(.reminders))
        limited.show(.pane(.networks))
        #expect(limited.selectedPaneForTesting == .reminders)
        #expect(!limited.tabViewItems.contains { $0.viewController is NetworksSettingsViewController })
    }

    @Test("A window whose pane runs below the screen moves up just enough, never past the top")
    func paneTallerThanTheRoomBelowLiftsTheWindow() {
        // A 1512×949 visible area, as on a 14-inch MacBook Pro with the Dock hidden.
        let visible = NSRect(x: 0, y: 0, width: 1_512, height: 949)
        // Networks' 376-point window with its top at 288: 88 points below the bottom edge.
        #expect(
            SettingsPaneMetrics.lifted(NSRect(x: 822, y: -88, width: 520, height: 376), into: visible)
                == NSRect(x: 822, y: 0, width: 520, height: 376))
        // Taller than the whole visible area: the top edge stays at its top.
        #expect(
            SettingsPaneMetrics.lifted(NSRect(x: 822, y: -400, width: 520, height: 1_000), into: visible)
                == NSRect(x: 822, y: -51, width: 520, height: 1_000))
        // Already inside: unchanged.
        #expect(
            SettingsPaneMetrics.lifted(NSRect(x: 822, y: 56, width: 520, height: 233), into: visible)
                == NSRect(x: 822, y: 56, width: 520, height: 233))
    }

    @Test("A window sitting mid-screen caps its pane at the room below its top edge")
    func midScreenWindowCapsAtTheRoomBelowIt() {
        // A 1440×875 visible area above a 25-point Dock, the window's top
        // edge halfway up it.
        let visible = NSRect(x: 0, y: 25, width: 1_440, height: 875)
        let chrome: CGFloat = 52
        #expect(
            SettingsPaneMetrics.maxHeight(windowTop: 462.5, visibleFrame: visible, chrome: chrome)
                == 462.5 - 25 - chrome)
        // A window not yet on a screen gets the whole visible height.
        #expect(
            SettingsPaneMetrics.maxHeight(windowTop: nil, visibleFrame: visible, chrome: chrome)
                == 875 - chrome)
    }
}
