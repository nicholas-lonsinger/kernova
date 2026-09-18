import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers how `MainWindowController` takes New VM out of the toolbar while the
/// sidebar is collapsed and puts it back: in the live toolbar, in the layout
/// AppKit autosaves, across a relaunch, and around the customize palette.
@Suite("MainWindowController New VM toolbar item", .admissionGated)
@MainActor
struct MainWindowControllerNewVMTests {
    private let autosave = WindowAutosaveScope.forTest()
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
        hideFromScreen(window)
        let split = try #require(window.contentViewController as? NSSplitViewController)
        return Subject(
            controller: controller,
            window: window,
            toolbar: try #require(window.toolbar),
            sidebar: try #require(split.splitViewItems.first { $0.behavior == .sidebar }))
    }

    private func tearDown(_ subject: Subject) {
        subject.window.close()
        autosave.removeSavedState(of: [subject.window])
    }

    /// Runs `body` on a first launch on this test's scope, closes it, and waits
    /// for AppKit to save its split layout — which `body` must change — so the
    /// next controller reads only what that launch saved.
    private func runFirstLaunch<Result>(_ body: (Subject) throws -> Result) async throws -> Result {
        weak var firstToolbar: NSToolbar?
        let result = try autoreleasepool {
            let first = try makeSubject()
            firstToolbar = first.toolbar
            let result: Result
            do {
                result = try body(first)
            } catch {
                tearDown(first)
                throw error
            }
            first.window.close()
            return result
        }

        let saved = AsyncGate()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in saved.notify() }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await saved.wait {
            UserDefaults.standard.object(forKey: WindowAutosaveScope.splitKey(autosave.mainSplit)) != nil
        }

        // "Toolbars with the same identifier are implicitly synchronized so that
        // they maintain the same state" (NSToolbar.h, `initWithIdentifier:`), so a
        // live first toolbar would hand the relaunch its layout directly.
        try #require(firstToolbar == nil, "The first launch's toolbar outlived it")
        return result
    }

    /// The toolbar layout AppKit saved for this scope. A saved configuration
    /// lists its items only when they differ from the delegate's default set, so
    /// a missing list reads as that set.
    private func savedLayout(of subject: Subject) -> [String] {
        let saved =
            UserDefaults.standard.dictionary(forKey: WindowAutosaveScope.toolbarKey(autosave.mainToolbar))?[
                "TB Item Identifiers"]
            as? [String]
        return saved
            ?? subject.controller.toolbarDefaultItemIdentifiers(subject.toolbar).map(\.rawValue)
    }

    // MARK: - Collapse and expand

    @Test("Collapsing the sidebar takes New VM out of the toolbar, and expanding puts it back")
    func collapseRemovesNewVM() throws {
        let subject = try makeSubject()
        defer { tearDown(subject) }
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
        defer { tearDown(subject) }
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

    // MARK: - Saved layout

    @Test("A collapse never reaches the saved toolbar layout")
    func collapseLeavesSavedLayout() throws {
        let subject = try makeSubject()
        defer { tearDown(subject) }
        let canonical = subject.layout
        try #require(savedLayout(of: subject) == canonical)

        subject.sidebar.isCollapsed = true
        try #require(!subject.layout.contains(newVM))

        #expect(savedLayout(of: subject) == canonical)
    }

    @Test("Expanding saves the restored layout, healing one an unrelated autosave saved without New VM")
    func expandHealsSavedLayout() throws {
        let subject = try makeSubject()
        defer { tearDown(subject) }
        let canonical = subject.layout
        subject.sidebar.isCollapsed = true
        subject.toolbar.displayMode = .iconAndLabel
        try #require(!savedLayout(of: subject).contains(newVM))

        subject.sidebar.isCollapsed = false

        #expect(savedLayout(of: subject) == canonical)
    }

    // MARK: - Relaunch

    @Test("A relaunch re-adopts a collapse removal its saved layout kept, and restores New VM on expand")
    func relaunchReadoptsSavedRemoval() async throws {
        defer { autosave.removeSavedState() }
        let canonical = try await runFirstLaunch { first in
            let canonical = first.layout
            first.sidebar.isCollapsed = true
            first.toolbar.displayMode = .iconAndLabel
            try #require(!savedLayout(of: first).contains(newVM))
            return canonical
        }

        let relaunched = try makeSubject()
        defer { tearDown(relaunched) }
        try #require(relaunched.sidebar.isCollapsed)
        try #require(!relaunched.layout.contains(newVM))
        #expect(preferences.mainToolbarNewVMCollapseIndex == 1)

        relaunched.sidebar.isCollapsed = false

        #expect(relaunched.layout == canonical)
        #expect(savedLayout(of: relaunched) == canonical)
        #expect(preferences.mainToolbarNewVMCollapseIndex == nil)
    }

    @Test("A relaunch with the sidebar collapsed takes New VM out again, though its saved layout has it")
    func collapsedRelaunchRemovesSavedNewVM() async throws {
        defer { autosave.removeSavedState() }
        let canonical = try await runFirstLaunch { first in
            let canonical = first.layout
            first.sidebar.isCollapsed = true
            return canonical
        }

        let relaunched = try makeSubject()
        defer { tearDown(relaunched) }
        try #require(relaunched.sidebar.isCollapsed)
        try #require(savedLayout(of: relaunched) == canonical)

        #expect(relaunched.layout == canonical.filter { $0 != newVM })
        #expect(preferences.mainToolbarNewVMCollapseIndex == 1)

        relaunched.sidebar.isCollapsed = false

        #expect(relaunched.layout == canonical)
    }

    @Test("A launch with New VM in the toolbar clears a stale collapse index")
    func launchClearsStaleIndex() throws {
        preferences.mainToolbarNewVMCollapseIndex = 1

        let subject = try makeSubject()
        defer { tearDown(subject) }

        try #require(!subject.sidebar.isCollapsed)
        #expect(subject.layout.contains(newVM))
        #expect(preferences.mainToolbarNewVMCollapseIndex == nil)
    }

    @Test("A New VM the user removed stays out through a collapse, an expand, and a relaunch")
    func customizationRemovalStaysOut() async throws {
        defer { autosave.removeSavedState() }
        try await runFirstLaunch { first in
            let index = try #require(first.layout.firstIndex(of: newVM))
            first.toolbar.removeItem(at: index)
            try #require(!savedLayout(of: first).contains(newVM))

            first.sidebar.isCollapsed = true
            #expect(preferences.mainToolbarNewVMCollapseIndex == nil)
            first.sidebar.isCollapsed = false

            #expect(!first.layout.contains(newVM))
            #expect(preferences.mainToolbarNewVMCollapseIndex == nil)
        }

        let relaunched = try makeSubject()
        defer { tearDown(relaunched) }

        #expect(!relaunched.layout.contains(newVM))
        #expect(preferences.mainToolbarNewVMCollapseIndex == nil)
    }

    // MARK: - Customize palette

    @Test("The customize palette shows New VM while the sidebar is collapsed, and the collapse returns when it closes")
    func paletteShowsCanonicalLayout() async throws {
        let subject = try makeSubject()
        defer { tearDown(subject) }
        let canonical = subject.layout
        subject.sidebar.isCollapsed = true
        try #require(!subject.layout.contains(newVM))

        subject.window.orderFront(nil)
        subject.toolbar.runCustomizationPalette(nil)
        let palette = try #require(subject.window.attachedSheet)
        hideFromScreen(palette)
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
        #expect(savedLayout(of: subject) == canonical)
    }
}
