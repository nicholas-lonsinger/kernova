import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers the reserved shortcuts end to end, short of a real key press: the
/// switch in the library, the key equivalent the menu bar shows for it, and
/// what `KernovaApplication.sendEvent(_:)` does with the press — taken ahead of
/// dispatch and run through the menu item while the menu shows it, dispatched
/// as usual (so a VM's screen sends it to the guest) while it does not.
///
/// The menus come from `makeMainMenu()` rather than `install()`, which writes
/// `NSApp.mainMenu` in the shared test host; the test host's `NSApp` is a plain
/// `NSApplication`, so each press goes to the ``ReservedShortcutCatcher`` the
/// app's `sendEvent(_:)` consults.
@Suite("Reserved shortcuts", .serialized, .caseScoped)
@MainActor
struct ReservedShortcutTests {
    private let preferences = makeTestPreferences()

    private struct Fixture {
        let viewModel: VMLibraryViewModel
        let controller: MainMenuController
        let mainMenu: NSMenu

        /// The menu item `shortcut` belongs to.
        @MainActor
        func item(for shortcut: ReservedShortcut) throws -> NSMenuItem {
            let items = mainMenu.items.compactMap(\.submenu).flatMap(\.items)
            return try #require(items.first { $0.action == shortcut.action })
        }
    }

    private func makeFixture(disabled: Set<ReservedShortcut> = []) -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        viewModel.disabledReservedShortcuts = disabled
        let controller = MainMenuController(viewModel: viewModel, windows: makeWindowRegistry(viewModel))
        return Fixture(viewModel: viewModel, controller: controller, mainMenu: controller.makeMainMenu())
    }

    /// Runs the menu bar's observation of the switches, which applies in a
    /// main-actor task the change enqueues ahead of this one.
    private func settle() async {
        await Task { @MainActor in }.value
    }

    /// Receives the two clipboard commands in place of the app delegate, which
    /// the test host has none of.
    private final class CommandRecorder: NSObject, NSMenuItemValidation {
        var received: [Selector] = []
        var isEnabled = true

        @objc func copyGuestClipboardToMac(_ sender: Any?) {
            received.append(#selector(AppDelegate.copyGuestClipboardToMac(_:)))
        }

        @objc func copyMacClipboardToGuest(_ sender: Any?) {
            received.append(#selector(AppDelegate.copyMacClipboardToGuest(_:)))
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabled }
    }

    private func press(
        _ type: NSEvent.EventType, _ key: String, keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = ReservedShortcut.modifierMask
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                keyCode: keyCode))
    }

    /// The US-layout key code of each shortcut's key.
    private func keyCode(_ shortcut: ReservedShortcut) -> UInt16 {
        switch shortcut {
        case .copyGuestClipboardToMac: 8
        case .copyMacClipboardToGuest: 9
        }
    }

    // MARK: - The menu

    @Test(
        "Turning a shortcut off and on again takes it off the menu and puts it back",
        arguments: ReservedShortcut.allCases)
    func flipUpdatesTheMenu(_ shortcut: ReservedShortcut) async throws {
        let fixture = makeFixture()
        let item = try fixture.item(for: shortcut)

        fixture.viewModel.setReservedShortcut(shortcut, isOn: false)
        await settle()
        #expect(item.keyEquivalent.isEmpty)

        fixture.viewModel.setReservedShortcut(shortcut, isOn: true)
        await settle()
        #expect(item.keyEquivalent == shortcut.keyEquivalent)
        #expect(item.keyEquivalentModifierMask == [.control, .shift, .command])
    }

    // MARK: - The press

    @Test(
        "A press of a shortcut that is on is taken and runs its item, down and up", arguments: ReservedShortcut.allCases
    )
    func onIsCaught(_ shortcut: ReservedShortcut) throws {
        let fixture = makeFixture()
        let recorder = CommandRecorder()
        try fixture.item(for: shortcut).target = recorder
        let catcher = ReservedShortcutCatcher()
        let key = shortcut.keyEquivalent

        #expect(catcher.catches(try press(.keyDown, key, keyCode: keyCode(shortcut)), in: fixture.mainMenu))
        #expect(recorder.received == [shortcut.action])
        #expect(catcher.catches(try press(.keyUp, key, keyCode: keyCode(shortcut)), in: fixture.mainMenu))
    }

    @Test("Shift's capital reads as the same shortcut", arguments: ReservedShortcut.allCases)
    func capitalIsCaught(_ shortcut: ReservedShortcut) throws {
        let fixture = makeFixture()
        let recorder = CommandRecorder()
        try fixture.item(for: shortcut).target = recorder

        let down = try press(.keyDown, shortcut.keyEquivalent.uppercased(), keyCode: keyCode(shortcut))
        #expect(ReservedShortcutCatcher().catches(down, in: fixture.mainMenu))
        #expect(recorder.received == [shortcut.action])
    }

    @Test("A shortcut that is on is taken while its item is disabled, and nothing runs")
    func disabledItemStillCaught() throws {
        let fixture = makeFixture()
        let recorder = CommandRecorder()
        recorder.isEnabled = false
        try fixture.item(for: .copyGuestClipboardToMac).target = recorder

        let down = try press(.keyDown, "c", keyCode: 8)
        #expect(ReservedShortcutCatcher().catches(down, in: fixture.mainMenu))
        #expect(recorder.received.isEmpty)
    }

    @Test("Other combinations of the same keys are dispatched as usual")
    func otherCombinationsPassThrough() throws {
        let fixture = makeFixture()
        let catcher = ReservedShortcutCatcher()

        for modifiers: NSEvent.ModifierFlags in [
            [.command], [.control, .command], [.shift, .command], [.control, .shift],
        ] {
            #expect(!catcher.catches(try press(.keyDown, "c", keyCode: 8, modifiers: modifiers), in: fixture.mainMenu))
        }
        #expect(!catcher.catches(try press(.keyDown, "x", keyCode: 7), in: fixture.mainMenu))
        // A release the catcher never took a press for is not its to take.
        #expect(!catcher.catches(try press(.keyUp, "c", keyCode: 8), in: fixture.mainMenu))
    }
}
