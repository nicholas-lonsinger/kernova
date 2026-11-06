import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Behavior tests for the Keyboard settings pane: the list of reserved
/// shortcuts, and the switches that turn them on and off.
@Suite("Keyboard Settings Tests", .serialized, .caseScoped)
@MainActor
struct KeyboardSettingsViewControllerTests {
    private let preferences = makeTestPreferences()

    private func makeLaidOutController(
        _ viewModel: VMLibraryViewModel
    ) -> KeyboardSettingsViewController {
        let controller = KeyboardSettingsViewController(viewModel: viewModel)
        _ = controller.view
        controller.viewWillAppear()
        controller.view.setFrameSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func toggle(_ toggle: NSSwitch, on: Bool) throws {
        toggle.state = on ? .on : .off
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
    }

    @Test("The pane lists every reserved shortcut, in order, with its command, keys and info")
    func listsEveryShortcut() throws {
        let controller = makeLaidOutController(makeLibraryViewModel(preferences: preferences))
        let view = controller.view

        #expect(findLabel(withText: KeyboardSettingsViewController.sectionTitle, in: view) != nil)
        #expect(controller.switches.map(\.shortcut) == ReservedShortcut.allCases)
        #expect(controller.switches.map(\.shortcut) == [.copyGuestClipboardToMac, .copyMacClipboardToGuest])
        for shortcut in ReservedShortcut.allCases {
            #expect(findLabel(withText: shortcut.commandTitle, in: view) != nil)
            #expect(findLabel(withText: shortcut.displayString, in: view) != nil)
        }
        #expect(ReservedShortcut.copyGuestClipboardToMac.displayString == "⌃⇧⌘C")
        #expect(ReservedShortcut.copyMacClipboardToGuest.displayString == "⌃⇧⌘V")
        let infoButtons = allSubviews(InfoButtonView.self, in: view)
        #expect(infoButtons.count == ReservedShortcut.allCases.count)
    }

    @Test("Each row's info says what on and off do with its keys", arguments: ReservedShortcut.allCases)
    func infoNamesOnAndOff(_ shortcut: ReservedShortcut) {
        let text = KeyboardSettingsViewController.infoParagraphs(for: shortcut).map { paragraph in
            switch paragraph {
            case .body(let text), .code(let text): text
            }
        }

        #expect(text.count == 2)
        #expect(text[0].hasPrefix("On: \(shortcut.displayString) chooses Edit › \(shortcut.commandTitle)"))
        #expect(text[0].contains("never receives \(shortcut.displayString)"))
        #expect(text[1].hasPrefix("Off:"))
        #expect(text[1].contains("sends \(shortcut.displayString) to the guest"))
    }

    @Test("The switches start on, and show a shortcut stored off as off")
    func switchesReflectTheStore() throws {
        let fresh = makeLaidOutController(makeLibraryViewModel(preferences: preferences))
        #expect(fresh.switches.allSatisfy { $0.control.state == .on })

        preferences.disabledReservedShortcuts = [.copyMacClipboardToGuest]
        let stored = makeLaidOutController(makeLibraryViewModel(preferences: preferences))
        #expect(stored.switches.map(\.control.state) == [.on, .off])
    }

    @Test(
        "A switch turns its shortcut off and on, and the choice outlives the library",
        arguments: ReservedShortcut.allCases)
    func switchPersists(_ shortcut: ReservedShortcut) throws {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let controller = makeLaidOutController(viewModel)
        let control = try #require(controller.switches.first { $0.shortcut == shortcut }?.control)

        try toggle(control, on: false)
        #expect(viewModel.disabledReservedShortcuts == [shortcut])
        // A library over the same store is the next launch.
        #expect(makeLibraryViewModel(preferences: preferences).disabledReservedShortcuts == [shortcut])

        try toggle(control, on: true)
        #expect(viewModel.disabledReservedShortcuts.isEmpty)
        #expect(makeLibraryViewModel(preferences: preferences).disabledReservedShortcuts.isEmpty)
    }

    @Test("Settings offers the Keyboard pane after Clipboard")
    func paneIsOffered() {
        let tabs = SettingsTabViewController(viewModel: makeLibraryViewModel(preferences: preferences))
        tabs.loadViewIfNeeded()

        let labels = tabs.tabViewItems.map(\.label)
        let clipboard = labels.firstIndex(of: "Clipboard")
        #expect(clipboard.map { labels[$0 + 1] } == "Keyboard")
        #expect(
            tabs.tabViewItems.first { $0.label == "Keyboard" }?.viewController
                is KeyboardSettingsViewController)
    }
}
