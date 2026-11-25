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

    // MARK: - Unavailable reasons

    @Test(
        "Without passthrough, USB Device is dimmed with what it needs as its subtitle",
        arguments: [
            (USBAccessoryPassthrough.Gap.needsMacOS(27), "Kernova needs macOS 27 or later for USB accessory passthrough."),
            (.needsEntitlement, "This build of Kernova does not support USB accessory passthrough."),
        ])
    func usbDeviceNamesWhatPassthroughNeeds(gap: USBAccessoryPassthrough.Gap, reason: String) throws {
        let viewModel = makeLibraryViewModel(preferences: preferences, usbAccessoryPassthrough: .unavailable(gap))
        let controller = MainMenuController(viewModel: viewModel, windows: makeWindowRegistry(viewModel))
        let vmMenu = try #require(submenu(titled: "Virtual Machine", in: controller.makeMainMenu()))
        vmMenu.update()

        let usb = try #require(vmMenu.items.first { $0.title == "USB Device" })
        #expect(!usb.isEnabled)
        #expect(usb.subtitle == reason)
        #expect(usb.toolTip == nil)
    }

    @Test("With passthrough, USB Device opens its accessory list and has no subtitle")
    func usbDeviceOpensWithPassthrough() throws {
        let viewModel = makeLibraryViewModel(
            preferences: preferences, usbAccessoryPassthrough: .available(MockUSBAccessoryService()))
        let controller = MainMenuController(viewModel: viewModel, windows: makeWindowRegistry(viewModel))
        let vmMenu = try #require(submenu(titled: "Virtual Machine", in: controller.makeMainMenu()))

        let usb = try #require(vmMenu.items.first { $0.title == "USB Device" })
        #expect(usb.submenu?.items.map(\.title) == ["No USB Accessories"])
        #expect(usb.subtitle == nil)
    }

    @Test("A clipboard command a running VM can't take is dimmed with why as its subtitle")
    func clipboardCommandNamesWhyItIsUnavailable() throws {
        let fixture = makeFixture()
        let instance = fixture.viewModel.library.registerFixture(
            guestOS: .macOS, phase: .running(sessionID: UUID())
        ) { $0.clipboardSharingEnabled = false }
        let editMenu = try #require(submenu(titled: "Edit", in: fixture.mainMenu))
        let toMac = try #require(editMenu.items.first { $0.title == "Copy Guest Clipboard to Mac" })

        #expect(!fixture.controller.validate(toMac, workingInstance: instance))
        #expect(toMac.subtitle == "Turned off in Settings.")
        #expect(toMac.toolTip == nil)
    }

    @Test("Add to Folder and Tags, dimmed while the organization file can't be read, say why as their subtitle")
    func sidebarItemsNameWhyTheyAreUnavailable() {
        let reason =
            "Kernova can\u{2019}t read its smart groups, folders and tags. Choose File > Check Config Files\u{2026} to review them."
        let menu = SidebarViewMenu(networkTitle: { _ in "" }, tags: { nil }, perform: { _ in })
        let items = [
            menu.addToFolderItem(entry: UUID(), folders: nil),
            menu.tagsItem(entry: UUID(), assigned: [], isEnabled: true),
        ]
        for item in items {
            #expect(!item.isEnabled)
            #expect(item.subtitle == reason)
            #expect(item.toolTip == nil)
        }
    }
}
