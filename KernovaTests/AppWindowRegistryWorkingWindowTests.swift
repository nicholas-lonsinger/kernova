import AppKit
import Testing

@testable import Kernova

/// Covers `AppWindowRegistry.workingInstance(keyWindow:mainWindow:)` — the VM
/// the menu bar's commands act on — handed the key and main windows rather
/// than reading them, so no case depends on what the shared test host has key.
@Suite("AppWindowRegistry working window", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct AppWindowRegistryWorkingWindowTests {
    private let preferences = makeTestPreferences()

    private struct Fixture {
        let viewModel: VMLibraryViewModel
        let registry: AppWindowRegistry
    }

    private func makeFixture() -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        return Fixture(viewModel: viewModel, registry: makeWindowRegistry(viewModel))
    }

    /// The library window, shown for `registry`.
    private func showLibrary(_ registry: AppWindowRegistry) throws -> NSWindow {
        registry.showLibrary(bringToFront: false)
        let window = try #require(registry.libraryWindow)
        adoptAppWindow(window)
        return window
    }

    @Test("A sheet answers for the VM of the window it is attached to")
    func sheetResolvesThroughItsParent() throws {
        let fixture = makeFixture()
        makeMenuInstance(in: fixture.viewModel, name: "Selected")
        let instance = VMInstanceFixture.make(name: "Clipboard VM", phase: .running(sessionID: UUID())) {
            $0.clipboardSharingEnabled = true
        }
        fixture.registry.showClipboard(for: instance)
        let clipboard = try #require(fixture.registry.clipboardWindow(for: instance.instanceID))
        adoptAppWindow(clipboard)
        let sheet = makeTestWindow(styleMask: [.titled])
        clipboard.beginSheet(sheet)
        #expect(sheet.sheetParent === clipboard)

        #expect(fixture.registry.workingInstance(keyWindow: sheet, mainWindow: clipboard) === instance)
        #expect(fixture.registry.workingInstance(keyWindow: sheet, mainWindow: nil) === instance)
    }

    @Test("The library window answers for its selection while it is key")
    func keyLibraryAnswersItsSelection() throws {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel)
        let library = try showLibrary(fixture.registry)

        #expect(fixture.registry.workingInstance(keyWindow: library, mainWindow: library) === instance)
    }

    @Test("The library window answers for its selection while it is main behind a key window showing no VM")
    func mainLibraryAnswersBehindANonVMKeyWindow() throws {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel)
        let library = try showLibrary(fixture.registry)
        let other = showTestWindow(styleMask: [.titled])

        #expect(fixture.registry.workingInstance(keyWindow: other, mainWindow: library) === instance)
    }

    @Test("With the library window closed, a key window showing no VM leaves no VM to act on")
    func closedLibraryAnswersNothing() throws {
        let fixture = makeFixture()
        makeMenuInstance(in: fixture.viewModel)
        let library = try showLibrary(fixture.registry)
        library.close()
        let other = showTestWindow(styleMask: [.titled])

        #expect(fixture.registry.workingInstance(keyWindow: other, mainWindow: other) == nil)
        #expect(fixture.registry.workingInstance(keyWindow: other, mainWindow: library) == nil)
        #expect(fixture.registry.workingInstance(keyWindow: nil, mainWindow: nil) == nil)
    }

    @Test("A working window showing no VM leaves the VM commands disabled")
    func noWorkingVMDisablesVMCommands() throws {
        let fixture = makeFixture()
        makeMenuInstance(in: fixture.viewModel)
        let other = showTestWindow(styleMask: [.titled])
        let controller = MainMenuController(
            viewModel: fixture.viewModel, windows: fixture.registry, hasBundledGuestAgentDisk: true)
        let working = fixture.registry.workingInstance(keyWindow: other, mainWindow: other)

        #expect(working == nil)
        #expect(
            !controller.validate(
                makeMenuItem(#selector(AppDelegate.startVM(_:))), workingInstance: working))
        #expect(
            !controller.validate(
                makeMenuItem(#selector(AppDelegate.deleteVM(_:))), workingInstance: working))
    }
}
