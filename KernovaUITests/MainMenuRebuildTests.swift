import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers the Edit menu `MainMenuController` builds: its clipboard commands.
///
/// The menus come from `makeMainMenu()` rather than `install()`, which writes
/// `NSApp.mainMenu` in the shared test host.
@Suite("MainMenuController rebuilds", .serialized, .caseScoped)
@MainActor
struct MainMenuRebuildTests {
    private let preferences = makeTestPreferences()

    /// The controller under test, over an empty library, and the menu bar it
    /// builds.
    private struct Fixture {
        let controller: MainMenuController
        let viewModel: VMLibraryViewModel
        let mainMenu: NSMenu
    }

    private func makeFixture() -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        viewModel.keepInMenuBarOnQuit = false
        let controller = MainMenuController(
            viewModel: viewModel, windows: makeWindowRegistry(viewModel))
        return Fixture(
            controller: controller, viewModel: viewModel, mainMenu: controller.makeMainMenu())
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
}
