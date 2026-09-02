import AppKit
import Testing

@testable import Kernova

/// Covers what `MainMenuController.menuNeedsUpdate(_:)` does to each menu it is
/// the delegate of: the app menu's quit section, the revert submenu, and the
/// Window menu's clipboard item.
///
/// The menus come from `makeMainMenu()` rather than `install()`, which writes
/// `NSApp.mainMenu` in the shared test host.
@Suite("MainMenuController rebuilds", .serialized, .admissionGated)
@MainActor
struct MainMenuRebuildTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.mainmenurebuild")

    private struct Fixture {
        let controller: MainMenuController
        let host: StubMenuHost
        let viewModel: VMLibraryViewModel
        let mainMenu: NSMenu
    }

    private func makeFixture(instance: VMInstance?, keepInMenuBar: Bool = false) -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        viewModel.keepInMenuBarOnQuit = keepInMenuBar
        let controller = MainMenuController(
            viewModel: viewModel, preferences: preferences, hasSoftQuit: true,
            hasBundledGuestAgentDisk: true)
        let host = StubMenuHost(instance: instance)
        controller.host = host
        return Fixture(
            controller: controller, host: host, viewModel: viewModel,
            mainMenu: controller.makeMainMenu())
    }

    /// The quit section: the trailing items the rebuild owns, matched by count
    /// against the model it is built from.
    private func quitItems(in appMenu: NSMenu, count: Int) -> [NSMenuItem] {
        Array(appMenu.items.suffix(count))
    }

    // MARK: - App menu quit section

    @Test("The quit section is built from the model for the current mode")
    func quitSectionMatchesModel() throws {
        let fixture = makeFixture(instance: nil)
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let model = MainMenuController.appMenuQuitItems(downgradesQuitToGUIClose: false)

        let items = quitItems(in: appMenu, count: model.count)
        #expect(items.map(\.title) == model.map(\.title))
        #expect(items.first?.keyEquivalentModifierMask == [.command])
    }

    @Test("An update with the preference unchanged keeps the same items")
    func unchangedModelKeepsItems() throws {
        let fixture = makeFixture(instance: nil)
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let before = quitItems(in: appMenu, count: 1)

        fixture.controller.menuNeedsUpdate(appMenu)

        let after = quitItems(in: appMenu, count: 1)
        #expect(before.count == 1)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
    }

    @Test("Flipping the residency preference replaces exactly the quit section")
    func flippedPreferenceReplacesQuitSection() throws {
        let fixture = makeFixture(instance: nil)
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let before = quitItems(in: appMenu, count: 1)
        let itemCountBefore = appMenu.items.count

        fixture.viewModel.keepInMenuBarOnQuit = true
        fixture.controller.menuNeedsUpdate(appMenu)

        let model = MainMenuController.appMenuQuitItems(downgradesQuitToGUIClose: true)
        let after = quitItems(in: appMenu, count: model.count)
        #expect(after.map(\.title) == model.map(\.title))
        #expect(after.last?.keyEquivalentModifierMask == [.command, .option])
        // Removes exactly what it added: the section grew by one, and no item
        // from the previous section is still in the menu.
        #expect(appMenu.items.count == itemCountBefore + 1)
        #expect(!appMenu.items.contains { item in before.contains { $0 === item } })
    }

    @Test("A foreign item in the quit section does not survive a rebuild")
    func foreignQuitSectionItemDoesNotSurviveARebuild() throws {
        let fixture = makeFixture(instance: nil)
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        // Stands in for the alternate AppKit injects beside a `terminate:` item:
        // the rebuild never created it, so only a positional sweep clears it.
        let intruder = NSMenuItem(
            title: "Quit and Keep Windows", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        intruder.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(intruder)
        // Ahead of the section start, so the sweep's lower bound is asserted and
        // not just its effect.
        let bystander = NSMenuItem(title: "Bystander", action: nil, keyEquivalent: "")
        appMenu.insertItem(bystander, at: 0)

        fixture.viewModel.keepInMenuBarOnQuit = true
        fixture.controller.menuNeedsUpdate(appMenu)

        let model = MainMenuController.appMenuQuitItems(downgradesQuitToGUIClose: true)
        #expect(!appMenu.items.contains { $0 === intruder })
        #expect(appMenu.items.first === bystander)
        #expect(quitItems(in: appMenu, count: model.count).map(\.title) == model.map(\.title))
    }

    @Test("An item injected into the quit section is swept even with the model unchanged")
    func injectedItemIsSweptWithoutAModelChange() throws {
        let fixture = makeFixture(instance: nil, keepInMenuBar: true)
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let model = MainMenuController.appMenuQuitItems(downgradesQuitToGUIClose: true)
        // What AppKit attaches beside a `terminate:` item, arriving after the
        // section was built and without anything the model would notice.
        let intruder = NSMenuItem(
            title: "Quit and Keep Windows", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        intruder.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(intruder)

        fixture.controller.menuNeedsUpdate(appMenu)

        let items = quitItems(in: appMenu, count: model.count)
        #expect(!appMenu.items.contains { $0 === intruder })
        #expect(items.map(\.title) == model.map(\.title))
        // ⌥⌘Q is the true quit's again, not the alternate's.
        let claimants = appMenu.items.filter {
            $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == [.command, .option]
        }
        #expect(claimants.count == 1)
        #expect(claimants.first?.action == #selector(AppDelegate.quitCompletely(_:)))
    }

    @Test("Only the full-quit item claims ⌥⌘Q after a toggle")
    func optionCommandQIsOwnedByTheFullQuit() throws {
        let fixture = makeFixture(instance: nil)
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let intruder = NSMenuItem(
            title: "Quit and Keep Windows", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        intruder.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(intruder)

        fixture.viewModel.keepInMenuBarOnQuit = true
        fixture.controller.menuNeedsUpdate(appMenu)

        let claimants = appMenu.items.filter {
            $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == [.command, .option]
        }
        #expect(claimants.count == 1)
        #expect(claimants.first?.action == #selector(AppDelegate.quitCompletely(_:)))
    }

    @Test("A toggled menu matches one freshly built in the same mode")
    func toggledMenuMatchesAFreshlyBuiltOne() throws {
        let fixture = makeFixture(instance: nil)
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let intruder = NSMenuItem(
            title: "Quit and Keep Windows", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        intruder.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(intruder)

        fixture.viewModel.keepInMenuBarOnQuit = true
        fixture.controller.menuNeedsUpdate(appMenu)

        let fresh = makeFixture(instance: nil, keepInMenuBar: true)
        let freshAppMenu = try #require(fresh.mainMenu.items.first?.submenu)
        #expect(appMenu.items.count == freshAppMenu.items.count)
        #expect(appMenu.items.map(\.title) == freshAppMenu.items.map(\.title))
    }

    // MARK: - Revert submenu

    @Test("An update with the same snapshots keeps the same items")
    func revertSubmenuUnchangedModel() throws {
        let instance = makeMenuInstance()
        let fixture = makeFixture(instance: instance)
        let revertMenu = try #require(revertSubmenu(in: fixture.mainMenu))
        let before = revertMenu.items

        fixture.controller.menuNeedsUpdate(revertMenu)

        #expect(before.count == 1)
        #expect(before.first?.title == SnapshotRevertMenu.emptyTitle)
        #expect(zip(before, revertMenu.items).allSatisfy { $0 === $1 })
    }

    @Test("A snapshot taken since the last open rebuilds the submenu")
    func revertSubmenuFollowsManifest() throws {
        let instance = makeMenuInstance()
        let fixture = makeFixture(instance: instance)
        let revertMenu = try #require(revertSubmenu(in: fixture.mainMenu))

        instance.snapshotManifest.snapshots = [VMSnapshot(name: "Clean")]
        fixture.controller.menuNeedsUpdate(revertMenu)

        // Each item renders two lines, so its title is matched by prefix.
        #expect(revertMenu.items.count == 1)
        #expect(revertMenu.items.first?.title.hasPrefix("Clean\u{2026}") == true)
        #expect(revertMenu.items.first?.isEnabled == true)
    }

    @Test("Opening the Virtual Machine menu rebuilds the revert submenu")
    func parentMenuRebuildsRevertSubmenu() throws {
        let instance = makeMenuInstance()
        let fixture = makeFixture(instance: instance)
        let vmMenu = try #require(submenu(titled: "Virtual Machine", in: fixture.mainMenu))
        let revertMenu = try #require(revertSubmenu(in: fixture.mainMenu))

        instance.snapshotManifest.snapshots = [VMSnapshot(name: "Clean")]
        fixture.controller.menuNeedsUpdate(vmMenu)

        #expect(revertMenu.items.count == 1)
        #expect(revertMenu.items.first?.title.hasPrefix("Clean\u{2026}") == true)
    }

    // MARK: - Window menu

    @Test("The clipboard item follows the active VM's clipboard availability")
    func clipboardItemFollowsActiveInstance() throws {
        let instance = makeMenuInstance(guestOS: .linux, phase: .running(sessionID: UUID()))
        instance.configuration.clipboardSharingEnabled = true
        let fixture = makeFixture(instance: instance)
        let windowMenu = try #require(submenu(titled: "Window", in: fixture.mainMenu))
        let clipboardItem = try #require(windowMenu.items.first { $0.title == "Clipboard" })

        fixture.controller.menuNeedsUpdate(windowMenu)
        #expect(clipboardItem.isEnabled)

        fixture.host.instance = nil
        fixture.controller.menuNeedsUpdate(windowMenu)
        #expect(!clipboardItem.isEnabled)
    }

    private func revertSubmenu(in mainMenu: NSMenu) -> NSMenu? {
        submenu(titled: "Virtual Machine", in: mainMenu)?
            .items.first { $0.title == SnapshotRevertMenu.title }?.submenu
    }
}
