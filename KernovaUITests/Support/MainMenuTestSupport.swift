import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// Shared fixtures for the app-level suites that build AppKit components; the
/// view model they build over is `makeLibraryViewModel(preferences:)`.

/// The app's window registry over `viewModel`, its windows off the desktop
/// and its requests of the session's focus going to `focus`.
@MainActor
func makeWindowRegistry(
    _ viewModel: VMLibraryViewModel, focus: RecordingSessionFocus = RecordingSessionFocus()
) -> AppWindowRegistry {
    let stage = WindowStage.offDesktop()
    return AppWindowRegistry(
        viewModel: viewModel,
        displayPlacement: VMDisplayPlacementController(viewModel: viewModel, stage: stage, focus: focus),
        stage: stage, focus: focus)
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
