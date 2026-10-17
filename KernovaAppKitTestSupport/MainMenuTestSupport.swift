import AppKit
import KernovaKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

// KernovaTests compiles the test-support folders into its own module;
// KernovaUITests links them as products.
#if !TEST_SUPPORT_COMPILED_IN
import KernovaTestSupport
@testable import KernovaCoreTestSupport
#endif

/// Shared fixtures for the app-level suites that build AppKit components; the
/// view model they build over is `makeLibraryViewModel(preferences:)`.

/// The app's window registry over `viewModel`, its windows off the desktop
/// and its activation requests going to `presence`.
@MainActor
func makeWindowRegistry(
    _ viewModel: VMLibraryViewModel, presence: TestAppPresence = TestAppPresence()
) -> AppWindowRegistry {
    let stage = WindowStage.offDesktop()
    return AppWindowRegistry(
        viewModel: viewModel,
        displayPlacement: VMDisplayPlacementController(viewModel: viewModel, stage: stage),
        stage: stage, presence: presence)
}

/// One menu item carrying `action`, as the menu bar builds it.
@MainActor
func makeMenuItem(_ action: Selector) -> NSMenuItem {
    NSMenuItem(title: "placeholder", action: action, keyEquivalent: "")
}

/// The submenu of the top-level menu titled `title`.
@MainActor
func submenu(titled title: String, in mainMenu: NSMenu) -> NSMenu? {
    mainMenu.items.compactMap(\.submenu).first { $0.title == title }
}
