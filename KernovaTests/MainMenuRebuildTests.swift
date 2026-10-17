import AppKit
import Testing

@testable import Kernova
@testable import KernovaCore

/// Covers what `MainMenuController.menuNeedsUpdate(_:)` does to each menu it is
/// the delegate of: the app menu's quit section, the revert submenu, and the
/// Window menu's clipboard item.
///
/// The menus come from `makeMainMenu()` rather than `install()`, which writes
/// `NSApp.mainMenu` in the shared test host.
@Suite("MainMenuController rebuilds", .serialized, .caseScoped)
@MainActor
struct MainMenuRebuildTests {
    private let preferences = makeTestPreferences()

    /// The controller under test, over a library a test selects the VM in
    /// (``makeMenuInstance(in:guestOS:name:phase:mutate:)``), which each check
    /// takes as the VM the working window shows.
    private struct Fixture {
        let controller: MainMenuController
        let viewModel: VMLibraryViewModel
        let mainMenu: NSMenu

        /// Validates `item` with the VM ``makeMenuInstance(in:guestOS:name:phase:mutate:)``
        /// selected as the one the working window shows.
        @MainActor
        func validate(_ item: NSMenuItem) -> Bool {
            controller.validate(item, workingInstance: viewModel.selectedInstance)
        }

        /// Updates `menu` with the VM ``makeMenuInstance(in:guestOS:name:phase:mutate:)``
        /// selected as the one the working window shows.
        @MainActor
        func update(_ menu: NSMenu) {
            controller.update(menu, workingInstance: viewModel.selectedInstance)
        }
    }

    /// `populate` runs before the menu bar is built, so a VM it selects is the
    /// one the menus are first built for.
    private func makeFixture(
        keepInMenuBar: Bool = false, populate: (VMLibraryViewModel) -> Void = { _ in }
    ) -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        viewModel.keepInMenuBarOnQuit = keepInMenuBar
        populate(viewModel)
        let controller = MainMenuController(
            viewModel: viewModel, windows: makeWindowRegistry(viewModel))
        return Fixture(
            controller: controller, viewModel: viewModel, mainMenu: controller.makeMainMenu())
    }

    /// The quit section: the trailing items the rebuild owns, matched by count
    /// against the model it is built from.
    private func quitItems(in appMenu: NSMenu, count: Int) -> [NSMenuItem] {
        Array(appMenu.items.suffix(count))
    }

    // MARK: - App menu quit section

    @Test("The quit section is built from the model for the current mode")
    func quitSectionMatchesModel() throws {
        let fixture = makeFixture()
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let model = AppMenuQuitItem.items(downgradesQuitToGUIClose: false)

        let items = quitItems(in: appMenu, count: model.count)
        #expect(items.map(\.title) == model.map(\.title))
        #expect(items.first?.keyEquivalentModifierMask == [.command])
    }

    @Test("Flipping the residency preference replaces exactly the quit section")
    func flippedPreferenceReplacesQuitSection() throws {
        let fixture = makeFixture()
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let before = quitItems(in: appMenu, count: 1)
        let itemCountBefore = appMenu.items.count

        fixture.viewModel.keepInMenuBarOnQuit = true
        fixture.update(appMenu)

        let model = AppMenuQuitItem.items(downgradesQuitToGUIClose: true)
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
        let fixture = makeFixture()
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
        fixture.update(appMenu)

        let model = AppMenuQuitItem.items(downgradesQuitToGUIClose: true)
        #expect(!appMenu.items.contains { $0 === intruder })
        #expect(appMenu.items.first === bystander)
        #expect(quitItems(in: appMenu, count: model.count).map(\.title) == model.map(\.title))
    }

    @Test("An item injected into the quit section is swept even with the model unchanged")
    func injectedItemIsSweptWithoutAModelChange() throws {
        let fixture = makeFixture(keepInMenuBar: true)
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let model = AppMenuQuitItem.items(downgradesQuitToGUIClose: true)
        let before = quitItems(in: appMenu, count: model.count)
        // What AppKit attaches beside a `terminate:` item, arriving after the
        // section was built and without anything the model would notice. It goes
        // between the modeled items, where AppKit puts it.
        let intruder = NSMenuItem(
            title: "Quit and Keep Windows", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        intruder.keyEquivalentModifierMask = [.command, .option]
        appMenu.insertItem(intruder, at: appMenu.items.count - 1)

        fixture.update(appMenu)

        let after = quitItems(in: appMenu, count: model.count)
        #expect(!appMenu.items.contains { $0 === intruder })
        #expect(after.map(\.title) == model.map(\.title))
        // Only the intruder was removed: the modeled items are the very ones the
        // section already held, never torn down and rebuilt.
        #expect(before.count == model.count)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
        // ⌥⌘Q is the true quit's again, not the alternate's.
        let claimants = appMenu.items.filter {
            $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == [.command, .option]
        }
        #expect(claimants.count == 1)
        #expect(claimants.first?.action == #selector(AppDelegate.quitCompletely(_:)))
    }

    @Test("A split quit section that already is the model is left untouched")
    func matchingSplitSectionIsNotMutated() throws {
        let fixture = makeFixture(keepInMenuBar: true)
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let model = AppMenuQuitItem.items(downgradesQuitToGUIClose: true)
        let before = quitItems(in: appMenu, count: model.count)
        let itemCountBefore = appMenu.items.count

        // Every ⌘-keystroke reaches this, so a matching section has to survive
        // repeated updates without a single mutation.
        fixture.update(appMenu)
        fixture.update(appMenu)

        let after = quitItems(in: appMenu, count: model.count)
        #expect(before.count == model.count)
        #expect(appMenu.items.count == itemCountBefore)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
    }

    @Test("A toggled menu matches one freshly built in the same mode")
    func toggledMenuMatchesAFreshlyBuiltOne() throws {
        let fixture = makeFixture()
        let appMenu = try #require(fixture.mainMenu.items.first?.submenu)
        let intruder = NSMenuItem(
            title: "Quit and Keep Windows", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        intruder.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(intruder)

        fixture.viewModel.keepInMenuBarOnQuit = true
        fixture.update(appMenu)

        let fresh = makeFixture(keepInMenuBar: true)
        let freshAppMenu = try #require(fresh.mainMenu.items.first?.submenu)
        #expect(appMenu.items.count == freshAppMenu.items.count)
        #expect(appMenu.items.map(\.title) == freshAppMenu.items.map(\.title))

        let claimants = appMenu.items.filter {
            $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == [.command, .option]
        }
        #expect(claimants.count == 1)
        #expect(claimants.first?.action == #selector(AppDelegate.quitCompletely(_:)))
    }

    // MARK: - Revert submenu

    @Test("An update with the same snapshots keeps the same items")
    func revertSubmenuUnchangedModel() throws {
        let fixture = makeFixture { makeMenuInstance(in: $0) }
        let revertMenu = try #require(revertSubmenu(in: fixture.mainMenu))
        fixture.update(revertMenu)
        let before = revertMenu.items

        fixture.update(revertMenu)

        #expect(before.count == 1)
        #expect(before.first?.title == SnapshotRevertMenu.emptyTitle)
        #expect(zip(before, revertMenu.items).allSatisfy { $0 === $1 })
    }

    @Test("A snapshot taken since the last open rebuilds the submenu")
    func revertSubmenuFollowsManifest() throws {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel)
        let revertMenu = try #require(revertSubmenu(in: fixture.mainMenu))

        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [VMSnapshot(name: "Clean", macAddress: nil)]))
        fixture.update(revertMenu)

        // Each item renders two lines, so its title is matched by prefix.
        #expect(revertMenu.items.count == 1)
        #expect(revertMenu.items.first?.title.hasPrefix("Clean\u{2026}") == true)
        #expect(revertMenu.items.first?.isEnabled == true)
    }

    @Test("Opening the Virtual Machine menu rebuilds the revert submenu")
    func parentMenuRebuildsRevertSubmenu() throws {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel)
        let vmMenu = try #require(submenu(titled: "Virtual Machine", in: fixture.mainMenu))
        let revertMenu = try #require(revertSubmenu(in: fixture.mainMenu))

        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [VMSnapshot(name: "Clean", macAddress: nil)]))
        fixture.update(vmMenu)

        #expect(revertMenu.items.count == 1)
        #expect(revertMenu.items.first?.title.hasPrefix("Clean\u{2026}") == true)
    }

    // MARK: - Window menu

    @Test("The clipboard item follows the active VM's clipboard availability")
    func clipboardItemFollowsActiveInstance() throws {
        let fixture = makeFixture()
        makeMenuInstance(in: fixture.viewModel, guestOS: .linux, phase: .running(sessionID: UUID())) {
            $0.clipboardSharingEnabled = true
        }
        let windowMenu = try #require(submenu(titled: "Window", in: fixture.mainMenu))
        let clipboardItem = try #require(windowMenu.items.first { $0.title == "Clipboard" })

        fixture.update(windowMenu)
        #expect(clipboardItem.isEnabled)

        fixture.viewModel.library.selection = nil
        fixture.update(windowMenu)
        #expect(!clipboardItem.isEnabled)
    }

    private func revertSubmenu(in mainMenu: NSMenu) -> NSMenu? {
        submenu(titled: "Virtual Machine", in: mainMenu)?
            .items.first { $0.title == SnapshotRevertMenu.title }?.submenu
    }
}
