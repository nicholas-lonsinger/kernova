import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers how `MainWindowController` takes New VM out of the toolbar while the
/// sidebar is collapsed and puts it back: in the live toolbar, in the layout
/// AppKit autosaves, across a relaunch, and around the customize palette.
///
/// Each test runs on an autosave scope of its own and removes what AppKit saved
/// under it, since the test host's `UserDefaults.standard` is the app's own
/// domain.
@Suite("MainWindowController New VM toolbar item", .admissionGated)
@MainActor
struct MainWindowControllerNewVMTests {
    private let scope = "test-\(UUID().uuidString)"
    private let preferences = makeTestPreferences()
    private let newVM = "newVM"

    private var toolbarAutosaveKey: String { "NSToolbar Configuration \(scope)Toolbar" }
    private var splitAutosaveKey: String { "NSSplitView Subview Frames \(scope)Split" }

    /// A controller and the AppKit objects a test drives and reads it through.
    @MainActor
    private struct Subject {
        let controller: MainWindowController
        let window: NSWindow
        let toolbar: NSToolbar
        let splitView: NSSplitView
        let sidebar: NSSplitViewItem

        var layout: [String] { toolbar.items.map(\.itemIdentifier.rawValue) }
    }

    private func makeSubject() throws -> Subject {
        let controller = MainWindowController(
            viewModel: makeLibraryViewModel(preferences: preferences),
            preferences: preferences,
            autosaveScope: scope)
        let window = try #require(controller.window)
        hideFromScreen(window)
        let split = try #require(window.contentViewController as? NSSplitViewController)
        return Subject(
            controller: controller,
            window: window,
            toolbar: try #require(window.toolbar),
            splitView: split.splitView,
            sidebar: try #require(split.splitViewItems.first { $0.behavior == .sidebar }))
    }

    /// Closes `subject`'s window and removes what AppKit saved under this
    /// test's scope.
    private func tearDown(_ subject: Subject) {
        subject.window.close()
        // NSSplitView saves a turn after a change (measured on macOS 27.0 26A428);
        // with the name cleared, a save still pending cannot write its key back
        // after the removal below.
        subject.splitView.autosaveName = nil
        subject.window.setFrameAutosaveName("")
        subject.toolbar.autosavesConfiguration = false
        removeAutosavedState()
    }

    private func removeAutosavedState() {
        for key in [toolbarAutosaveKey, "NSWindow Frame \(scope)Window", splitAutosaveKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Runs a first launch on this test's scope that collapses the sidebar,
    /// runs `whileCollapsed`, and closes, then waits for its split layout to be
    /// saved — so the next controller reads what that launch saved, sidebar
    /// collapsed.
    ///
    /// Returns the launch's toolbar layout from before the collapse.
    private func runCollapsedFirstLaunch(
        whileCollapsed body: (Subject) throws -> Void = { _ in }
    ) async throws -> [String] {
        weak var firstToolbar: NSToolbar?
        let canonical = try autoreleasepool {
            let first = try makeSubject()
            firstToolbar = first.toolbar
            let canonical = first.layout
            first.sidebar.isCollapsed = true
            do {
                try body(first)
            } catch {
                tearDown(first)
                throw error
            }
            first.window.close()
            return canonical
        }

        let saved = AsyncGate()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in saved.notify() }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await saved.wait { UserDefaults.standard.object(forKey: splitAutosaveKey) != nil }

        // "Toolbars with the same identifier are implicitly synchronized so that
        // they maintain the same state" (NSToolbar.h, `initWithIdentifier:`), so a
        // live first toolbar would hand the relaunch its layout directly.
        try #require(firstToolbar == nil, "The first launch's toolbar outlived it")
        return canonical
    }

    /// The toolbar layout AppKit saved for this scope. A saved configuration
    /// lists its items only when they differ from the delegate's default set, so
    /// a missing list reads as that set.
    private func savedLayout(of subject: Subject) -> [String] {
        let saved =
            UserDefaults.standard.dictionary(forKey: toolbarAutosaveKey)?["TB Item Identifiers"]
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
        defer { removeAutosavedState() }
        let canonical = try await runCollapsedFirstLaunch { first in
            first.toolbar.displayMode = .iconAndLabel
            try #require(!savedLayout(of: first).contains(newVM))
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
        defer { removeAutosavedState() }
        let canonical = try await runCollapsedFirstLaunch()

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
