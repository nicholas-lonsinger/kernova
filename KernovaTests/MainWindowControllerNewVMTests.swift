import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers how `MainWindowController` takes New VM out of the toolbar while the
/// sidebar is collapsed and puts it back: in the live toolbar, around a
/// customization the user made, and around the customize palette.
@Suite("MainWindowController New VM toolbar item", .admissionGated, .scopedWindows)
@MainActor
struct MainWindowControllerNewVMTests {
    private let autosave = WindowAutosaveScope.unsaved()
    private let preferences = makeTestPreferences()
    private let newVM = "newVM"

    /// A controller and the AppKit objects a test drives and reads it through.
    @MainActor
    private struct Subject {
        let controller: MainWindowController
        let window: NSWindow
        let toolbar: NSToolbar
        let sidebar: NSSplitViewItem

        var layout: [String] { toolbar.items.map(\.itemIdentifier.rawValue) }
    }

    private func makeSubject() throws -> Subject {
        let controller = MainWindowController(
            viewModel: makeLibraryViewModel(preferences: preferences),
            autosaveScope: autosave)
        let window = try #require(controller.window)
        adoptAppWindow(window)
        let split = try #require(window.contentViewController as? NSSplitViewController)
        return Subject(
            controller: controller,
            window: window,
            toolbar: try #require(window.toolbar),
            sidebar: try #require(split.splitViewItems.first { $0.behavior == .sidebar }))
    }

    // MARK: - Collapse and expand

    @Test("Collapsing the sidebar takes New VM out of the toolbar, and expanding puts it back")
    func collapseRemovesNewVM() throws {
        let subject = try makeSubject()
        let canonical = subject.layout
        try #require(canonical.firstIndex(of: newVM) == 1)

        subject.sidebar.isCollapsed = true

        #expect(subject.layout == canonical.filter { $0 != newVM })
        #expect(preferences.mainToolbarNewVMCollapseIndex == 1)

        subject.sidebar.isCollapsed = false

        #expect(subject.layout == canonical)
        #expect(preferences.mainToolbarNewVMCollapseIndex == nil)
    }

    @Test("Expanding returns New VM to its own slot in a customized layout, not beside the sidebar toggle")
    func expandRestoresCustomizedSlot() throws {
        let subject = try makeSubject()
        let index = try #require(subject.layout.firstIndex(of: newVM))
        subject.toolbar.removeItem(at: index)
        subject.toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(newVM), at: 0)
        let customized = subject.layout
        try #require(
            Array(customized.prefix(3)) == [
                newVM,
                NSToolbarItem.Identifier.flexibleSpace.rawValue,
                NSToolbarItem.Identifier.toggleSidebar.rawValue,
            ])

        subject.sidebar.isCollapsed = true
        #expect(preferences.mainToolbarNewVMCollapseIndex == 0)
        subject.sidebar.isCollapsed = false

        #expect(subject.layout == customized)
    }

    @Test("A New VM the user removed stays out through a collapse and an expand")
    func customizationRemovalStaysOut() throws {
        let subject = try makeSubject()
        let index = try #require(subject.layout.firstIndex(of: newVM))
        subject.toolbar.removeItem(at: index)

        subject.sidebar.isCollapsed = true
        #expect(preferences.mainToolbarNewVMCollapseIndex == nil)
        subject.sidebar.isCollapsed = false

        #expect(!subject.layout.contains(newVM))
        #expect(preferences.mainToolbarNewVMCollapseIndex == nil)
    }

    // MARK: - Launch

    @Test("A launch with New VM in the toolbar clears a stale collapse index")
    func launchClearsStaleIndex() throws {
        preferences.mainToolbarNewVMCollapseIndex = 1

        let subject = try makeSubject()

        try #require(!subject.sidebar.isCollapsed)
        #expect(subject.layout.contains(newVM))
        #expect(preferences.mainToolbarNewVMCollapseIndex == nil)
    }

    // MARK: - Customize palette

    @Test("The customize palette shows New VM while the sidebar is collapsed, and the collapse returns when it closes")
    func paletteShowsCanonicalLayout() async throws {
        let subject = try makeSubject()
        let canonical = subject.layout
        subject.sidebar.isCollapsed = true
        try #require(!subject.layout.contains(newVM))

        subject.window.orderFront(nil)
        subject.toolbar.runCustomizationPalette(nil)
        let palette = try #require(subject.window.attachedSheet)
        adoptAppWindow(palette)
        try #require(subject.toolbar.customizationPaletteIsRunning)

        #expect(subject.layout == canonical)

        let sheetEnded = Box(false)
        let gate = AsyncGate()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: subject.window, queue: .main
        ) { _ in
            sheetEnded.value = true
            gate.notify()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let paletteContent = try #require(palette.contentView)
        let done = try #require(findButton(titled: "Done", in: paletteContent))
        done.performClick(nil)
        try await gate.wait { sheetEnded.value }

        #expect(subject.layout == canonical.filter { $0 != newVM })
        #expect(preferences.mainToolbarNewVMCollapseIndex == 1)
    }
}
