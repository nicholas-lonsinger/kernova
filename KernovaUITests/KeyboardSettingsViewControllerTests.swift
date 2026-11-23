import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The Keyboard settings pane's switches that turn reserved shortcuts on and off.
@Suite("Keyboard Settings Tests", .serialized, .caseScoped)
@MainActor
struct KeyboardSettingsViewControllerTests {
    private let preferences = makeTestPreferences()

    private func makeLaidOutController(
        _ viewModel: VMLibraryViewModel
    ) -> KeyboardSettingsViewController {
        let controller = KeyboardSettingsViewController(viewModel: viewModel)
        _ = controller.view
        controller.refreshContent()
        controller.view.setFrameSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func toggle(_ toggle: NSSwitch, on: Bool) throws {
        toggle.state = on ? .on : .off
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
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
}
