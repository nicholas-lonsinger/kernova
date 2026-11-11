import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

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

    // MARK: - Edit menu

    @Test("The Edit menu carries the clipboard commands with their shortcuts, and the passthrough switch")
    func editMenuCarriesTheClipboardCommands() throws {
        let fixture = makeFixture()
        let editMenu = try #require(submenu(titled: "Edit", in: fixture.mainMenu))
        let toMac = try #require(editMenu.items.first { $0.title == "Copy Guest Clipboard to Mac" })
        #expect(toMac.action == #selector(AppDelegate.copyGuestClipboardToMac(_:)))
        #expect(toMac.keyEquivalent == "c")
        #expect(toMac.keyEquivalentModifierMask == [.control, .shift, .command])
        let toGuest = try #require(editMenu.items.first { $0.title == "Copy Mac Clipboard to Guest" })
        #expect(toGuest.action == #selector(AppDelegate.copyMacClipboardToGuest(_:)))
        #expect(toGuest.keyEquivalent == "v")
        #expect(toGuest.keyEquivalentModifierMask == [.control, .shift, .command])
        let passthrough = try #require(editMenu.items.first { $0.title == "Automatic Clipboard Passthrough" })
        #expect(passthrough.action == #selector(AppDelegate.toggleClipboardPassthrough(_:)))
        #expect(passthrough.keyEquivalent.isEmpty)
    }

    private func revertSubmenu(in mainMenu: NSMenu) -> NSMenu? {
        submenu(titled: "Virtual Machine", in: mainMenu)?
            .items.first { $0.title == SnapshotRevertMenu.title }?.submenu
    }
}
