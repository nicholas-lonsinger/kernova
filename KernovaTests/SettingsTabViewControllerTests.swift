import AppKit
import Foundation
import Testing

@testable import Kernova

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
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
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
        let tabController = SettingsTabViewController(viewModel: makeViewModel(vmCount: overflowingVMCount()))
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

    /// The cue must be spent *after* the window is ordered on screen: the flash
    /// animates a fade-in, so one started on the way in is already over by the
    /// time the window appears, and the pane's first visit shows a scroller that
    /// only fades out — unlike every visit after it.
    @Test("The pre-appearance hook does not spend the flash")
    func viewWillAppearDoesNotFlash() throws {
        let (tabController, pane) = try makeOverflowingPane()
        defer { pane.viewDidDisappear() }
        let indicator = try #require(pane.scrollMoreIndicatorForTesting)
        let before = indicator.flashCountForTesting

        tabController.viewWillAppear()

        #expect(indicator.flashCountForTesting == before)
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

    // MARK: - Destinations

    private func makeRegistry(_ viewModel: VMLibraryViewModel) -> AppWindowRegistry {
        let autosave = WindowAutosaveScope.unsaved()
        return AppWindowRegistry(
            viewModel: viewModel,
            displayPlacement: VMDisplayPlacementController(viewModel: viewModel, autosaveScope: autosave),
            autosaveScope: autosave)
    }

    private func tabs(of registry: AppWindowRegistry) throws -> SettingsTabViewController {
        let window = try #require(registry.settingsWindow)
        adoptAppWindow(window)
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
        let registry = makeRegistry(viewModel)

        registry.showSettings(at: .network(lab.id))

        let tabs = try tabs(of: registry)
        #expect(tabs.selectedPaneForTesting == .networks)
        #expect(try networksPane(in: tabs).selectedNetworkIDForTesting == lab.id)
    }

    @Test("Settings already open on another pane switches to the Networks pane and the network")
    func openWindowSwitchesToTheNetwork() throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let lab = try viewModel.networks.create(name: "Lab", kind: .nat, verb: .createNetwork)
        let registry = makeRegistry(viewModel)
        registry.showSettings(at: .pane(.clipboard))
        let tabs = try tabs(of: registry)
        #expect(tabs.selectedPaneForTesting == .clipboard)

        registry.showSettings(at: .network(lab.id))

        #expect(tabs.selectedPaneForTesting == .networks)
        #expect(try networksPane(in: tabs).selectedNetworkIDForTesting == lab.id)

        // With no destination, the window stays on the pane it was left on.
        registry.showSettings()
        #expect(tabs.selectedPaneForTesting == .networks)
    }

    @Test("⌘, opens Settings through the app's own action, which names no destination and keeps the last pane")
    func commandCommaKeepsTheLastPane() throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let controller = MainMenuController(viewModel: viewModel, hasBundledGuestAgentDisk: true)
        let appMenu = try #require(controller.makeMainMenu().items.first?.submenu)
        let settings = try #require(appMenu.items.first { $0.keyEquivalent == "," })
        #expect(settings.keyEquivalentModifierMask == [.command])
        #expect(settings.action == #selector(AppDelegate.showSettings(_:)))
        #expect(settings.representedObject == nil)

        let registry = makeRegistry(viewModel)
        registry.showSettings(at: .pane(.tags))
        registry.showSettings()
        #expect(try tabs(of: registry).selectedPaneForTesting == .tags)
    }

    @Test("Each pane is a destination, and one the build does not offer leaves the selection")
    func everyOfferedPaneIsADestination() throws {
        let tabController = SettingsTabViewController(viewModel: makeSettingsViewModel(preferences: preferences))
        for pane in SettingsPane.allCases {
            tabController.show(.pane(pane))
            #expect(tabController.selectedPaneForTesting == pane)
        }

        let unentitled = makeSettingsViewModel(preferences: preferences, entitled: false)
        let limited = SettingsTabViewController(viewModel: unentitled)
        limited.show(.pane(.reminders))
        limited.show(.pane(.networks))
        #expect(limited.selectedPaneForTesting == .reminders)
        #expect(!limited.tabViewItems.contains { $0.viewController is NetworksSettingsViewController })
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
