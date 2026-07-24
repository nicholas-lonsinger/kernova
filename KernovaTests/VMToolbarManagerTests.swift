import Cocoa
import KernovaKit
import Testing

@testable import Kernova

@Suite("VMToolbarManager Tests")
@MainActor
struct VMToolbarManagerTests {
    // MARK: - Factories

    private func makeInstance(status: VMStatus = .stopped) -> VMInstance {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

    private func makeManager(
        instance: VMInstance? = nil,
        checksPreparing: Bool = true,
        gatesDisplayOnCapability: Bool = true,
        includeSettingsToggle: Bool = true
    ) -> VMToolbarManager {
        VMToolbarManager(
            configuration: .init(
                lifecycleID: NSToolbarItem.Identifier("testLifecycle"),
                saveStateID: NSToolbarItem.Identifier("testSaveState"),
                clipboardID: NSToolbarItem.Identifier("testClipboard"),
                popOutID: NSToolbarItem.Identifier("testPopOut"),
                fullscreenID: NSToolbarItem.Identifier("testFullscreen"),
                settingsToggleID: includeSettingsToggle ? NSToolbarItem.Identifier("testSettingsToggle") : nil,
                checksPreparing: checksPreparing,
                gatesDisplayOnCapability: gatesDisplayOnCapability
            ),
            instanceProvider: { instance }
        )
    }

    private func item(_ rawIdentifier: String, in toolbar: NSToolbar) -> NSToolbarItem? {
        toolbar.items.first { $0.itemIdentifier.rawValue == rawIdentifier }
    }

    /// Creates an NSToolbar attached to a window so `toolbar.items` is populated via delegate callbacks.
    ///
    /// Pass `defaultItems` to populate only a subset of the manager's items, simulating a
    /// user-customized layout.
    private func makeToolbar(
        manager: VMToolbarManager,
        defaultItems: [NSToolbarItem.Identifier]? = nil
    ) -> (NSToolbar, NSWindow, ToolbarTestDelegate) {
        let delegate = ToolbarTestDelegate(manager: manager, defaultItems: defaultItems)
        let toolbar = NSToolbar(identifier: "test-\(UUID().uuidString)")
        toolbar.delegate = delegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.toolbar = toolbar
        return (toolbar, window, delegate)
    }

    // MARK: - Item Creation

    @Test("makeToolbarItem returns lifecycle group with 3 subitems")
    func lifecycleGroupStructure() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testLifecycle"))
        let group = item as? NSToolbarItemGroup
        #expect(group != nil)
        #expect(group?.subitems.count == 3)
        #expect(group?.label == "State Controls")
    }

    @Test("makeToolbarItem returns save state as a plain bordered item")
    func saveStateItemStructure() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testSaveState"))
        #expect(item != nil)
        #expect(!(item is NSToolbarItemGroup))
        #expect(item?.isBordered == true)
        #expect(item?.label == "Suspend")
        #expect(item?.autovalidates == false)
    }

    @Test("makeToolbarItem returns separate bordered pop-out and fullscreen items")
    func displayItemsStructure() {
        let manager = makeManager()
        let popOut = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testPopOut"))
        let fullscreen = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testFullscreen"))
        #expect(popOut?.isBordered == true)
        #expect(popOut?.label == "Pop Out")
        #expect(fullscreen?.isBordered == true)
        #expect(fullscreen?.label == "Fullscreen")
        // The runtime labels flip (Pop In / Exit Fullscreen); the customize
        // palette keeps the factory names.
        #expect(popOut?.paletteLabel == "Pop Out")
        #expect(fullscreen?.paletteLabel == "Fullscreen")
    }

    @Test("makeToolbarItem returns nil for unknown identifier")
    func unknownIdentifierReturnsNil() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("unknown"))
        #expect(item == nil)
    }

    @Test("sharedItemIdentifiers contains all configured identifiers")
    func sharedIdentifiers() {
        let manager = makeManager()
        #expect(manager.sharedItemIdentifiers.count == 6)
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testLifecycle")))
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testSaveState")))
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testClipboard")))
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testPopOut")))
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testFullscreen")))
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testSettingsToggle")))
    }

    @Test("sharedItemIdentifiers omits settings toggle when not configured")
    func sharedIdentifiersWithoutSettingsToggle() {
        let manager = makeManager(includeSettingsToggle: false)
        #expect(manager.sharedItemIdentifiers.count == 5)
        #expect(!manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testSettingsToggle")))
    }

    @Test("defaultItemIdentifiers separates the capsule clusters with fixed spaces")
    func defaultIdentifiersClusterSpacing() {
        let manager = makeManager()
        #expect(
            manager.defaultItemIdentifiers == [
                NSToolbarItem.Identifier("testLifecycle"),
                NSToolbarItem.Identifier("testSaveState"),
                .space,
                NSToolbarItem.Identifier("testClipboard"),
                .space,
                NSToolbarItem.Identifier("testPopOut"),
                NSToolbarItem.Identifier("testFullscreen"),
                .space,
                NSToolbarItem.Identifier("testSettingsToggle"),
            ])
    }

    @Test("defaultItemIdentifiers omits the trailing space without a settings toggle")
    func defaultIdentifiersWithoutSettingsToggle() {
        let manager = makeManager(includeSettingsToggle: false)
        #expect(
            manager.defaultItemIdentifiers == [
                NSToolbarItem.Identifier("testLifecycle"),
                NSToolbarItem.Identifier("testSaveState"),
                .space,
                NSToolbarItem.Identifier("testClipboard"),
                .space,
                NSToolbarItem.Identifier("testPopOut"),
                NSToolbarItem.Identifier("testFullscreen"),
            ])
    }

    // MARK: - Nil Instance

    @Test("All items disabled when instance is nil")
    func nilInstanceDisablesAll() {
        let manager = makeManager(instance: nil)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = item("testLifecycle", in: toolbar) as? NSToolbarItemGroup
        #expect(lifecycle?.subitems.allSatisfy { !$0.isEnabled } == true)
        #expect(item("testSaveState", in: toolbar)?.isEnabled == false)
        #expect(item("testPopOut", in: toolbar)?.isEnabled == false)
        #expect(item("testFullscreen", in: toolbar)?.isEnabled == false)
    }

    // MARK: - Clipboard item

    /// In-memory `ClipboardServicing` whose `transferProgress` a test sets
    /// directly to drive the toolbar item's transfer bar. `@Observable` so the
    /// manager's `observeRecurring` arms against it like a real transport.
    @MainActor
    @Observable
    final class FakeClipboardService: ClipboardServicing {
        var clipboardContent: ClipboardContent = .empty
        var isConnected = true
        var supportsBinaryRepresentations = true
        var supportsDirectoryTree = false
        var lastTransferIssue: ClipboardTransferIssue?
        var transferProgress: ClipboardTransferProgress?

        func stop() {}
        func grabIfChanged() {}
        func clearBuffer() { clipboardContent = .empty }
    }

    private func clipboardButton(in toolbar: NSToolbar) -> ClipboardToolbarButton? {
        item("testClipboard", in: toolbar)?.view as? ClipboardToolbarButton
    }

    @Test("makeToolbarItem returns the clipboard item backed by ClipboardToolbarButton")
    func clipboardItemStructure() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testClipboard"))
        #expect(item?.view is ClipboardToolbarButton)
        #expect(item?.label == "Clipboard")
        #expect(item?.paletteLabel == "Clipboard")
        #expect(item?.autovalidates == false)
    }

    @Test("Clipboard item carries a menu form representation for the overflow menu")
    func clipboardItemMenuFormRepresentation() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testClipboard"))

        // A view-backed item leaves `item.action` nil, so AppKit's automatic menu
        // form representation would be inert — the overflow ("»") entry has to be
        // supplied explicitly.
        let menuForm = item?.menuFormRepresentation
        #expect(menuForm != nil)
        #expect(menuForm?.title == "Clipboard")
        #expect(menuForm?.action == #selector(AppDelegate.showClipboard(_:)))
        // Nil target: the action travels the responder chain to AppDelegate.
        #expect(menuForm?.target == nil)
        #expect(menuForm?.image != nil)
    }

    @Test("Clipboard button hit-tests as one control over the transfer bar")
    func clipboardButtonHitTestOverTransferBar() {
        let button = ClipboardToolbarButton()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        button.transferFraction = 0.5
        container.layoutSubtreeIfNeeded()

        // Bar metrics (docs/TOOLBAR.md): 22×6 capsule, horizontally centered,
        // bottom edge 3 pt above the circle's rim — so (18, 6) is over the bar.
        // The button frame fills the container, making container coordinates and
        // the button's bounds coincide.
        #expect(button.hitTest(NSPoint(x: 18, y: 6)) === button)
        // Sanity: a point clear of the bar naturally lands on the button too.
        #expect(button.hitTest(NSPoint(x: 18, y: 26)) === button)
    }

    @Test("updateClipboardItem disables the clipboard item without a running VM")
    func clipboardItemDisabledForStoppedInstance() {
        let instance = makeInstance(status: .stopped)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        // canShowClipboard is false (a test instance has no VZVirtualMachine).
        #expect(clipboardButton(in: toolbar)?.isEnabled == false)
    }

    @Test("updateClipboardItem disables the clipboard item for a nil instance")
    func clipboardItemDisabledForNilInstance() {
        let manager = makeManager(instance: nil)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(clipboardButton(in: toolbar)?.isEnabled == false)
    }

    @Test("Clipboard button shows the transfer fraction while a transfer is in flight")
    func clipboardBarShownDuringTransfer() {
        let instance = makeInstance(status: .running)
        let service = FakeClipboardService()
        service.transferProgress = ClipboardTransferProgress(
            direction: .inbound, bytesTransferred: 25, totalBytes: 100, label: nil)
        instance.clipboardService = service
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(clipboardButton(in: toolbar)?.transferFraction == 0.25)
    }

    @Test("Clipboard button hides the bar once the transfer reaches a terminal state")
    func clipboardBarHiddenAfterTerminal() {
        let instance = makeInstance(status: .running)
        let service = FakeClipboardService()
        service.transferProgress = ClipboardTransferProgress(
            direction: .outbound, bytesTransferred: 50, totalBytes: 100, label: nil)
        instance.clipboardService = service
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)
        manager.updateToolbarItems(in: toolbar)
        #expect(clipboardButton(in: toolbar)?.transferFraction == 0.5)

        // Terminal: the tracker clears the projection.
        service.transferProgress = nil
        manager.updateToolbarItems(in: toolbar)

        #expect(clipboardButton(in: toolbar)?.transferFraction == nil)
    }

    // MARK: - Preparing State

    @Test("checksPreparing=true disables all when isPreparing")
    func checksPreparingDisablesAll() {
        let instance = makeInstance(status: .running)
        instance.preparingState = VMInstance.PreparingState(
            operation: .cloning,
            task: Task {}
        )
        let manager = makeManager(instance: instance, checksPreparing: true)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        #expect(lifecycle?.subitems.allSatisfy { !$0.isEnabled } == true)
    }

    @Test("checksPreparing=false ignores isPreparing")
    func skipPreparingCheck() {
        let instance = makeInstance(status: .running)
        instance.preparingState = VMInstance.PreparingState(
            operation: .cloning,
            task: Task {}
        )
        let manager = makeManager(instance: instance, checksPreparing: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        // With checksPreparing=false and status=running, pause should be enabled
        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        let pauseItem = lifecycle?.subitems[1]
        #expect(pauseItem?.isEnabled == true)
    }

    // MARK: - Lifecycle Labels

    @Test("Play button shows 'Start' when status is stopped")
    func playLabelStartWhenStopped() {
        let instance = makeInstance(status: .stopped)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        let playItem = lifecycle?.subitems[0]
        #expect(playItem?.label == "Start")
    }

    @Test("Play button shows 'Resume' when status is paused")
    func playLabelResumeWhenPaused() {
        let instance = makeInstance(status: .paused)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        let playItem = lifecycle?.subitems[0]
        #expect(playItem?.label == "Resume")
    }

    // MARK: - Lifecycle Enable States

    @Test("Play enabled when canStart (stopped)")
    func playEnabledWhenStopped() {
        let instance = makeInstance(status: .stopped)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        #expect(lifecycle?.subitems[0].isEnabled == true)  // play
        #expect(lifecycle?.subitems[1].isEnabled == false)  // pause
        #expect(lifecycle?.subitems[2].isEnabled == false)  // stop
    }

    @Test("Pause and stop enabled when running")
    func pauseStopEnabledWhenRunning() {
        let instance = makeInstance(status: .running)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        #expect(lifecycle?.subitems[0].isEnabled == false)  // play (can't start when running)
        #expect(lifecycle?.subitems[1].isEnabled == true)  // pause
        #expect(lifecycle?.subitems[2].isEnabled == true)  // stop
    }

    @Test("Play (resume) and stop enabled when paused")
    func resumeStopEnabledWhenPaused() {
        let instance = makeInstance(status: .paused)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        #expect(lifecycle?.subitems[0].isEnabled == true)  // resume
        #expect(lifecycle?.subitems[1].isEnabled == false)  // pause (already paused)
        #expect(lifecycle?.subitems[2].isEnabled == true)  // stop
    }

    @Test("All lifecycle items disabled during transitioning states")
    func lifecycleDisabledDuringTransition() {
        let instance = makeInstance(status: .starting)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        #expect(lifecycle?.subitems.allSatisfy { !$0.isEnabled } == true)
    }

    // MARK: - Save State

    @Test("Save state enabled when canSave (running)")
    func saveEnabledWhenRunning() {
        let instance = makeInstance(status: .running)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testSaveState", in: toolbar)?.isEnabled == true)
    }

    @Test("Save state disabled when stopped")
    func saveDisabledWhenStopped() {
        let instance = makeInstance(status: .stopped)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testSaveState", in: toolbar)?.isEnabled == false)
    }

    // MARK: - Display Item Gating

    @Test("Display items disabled when gatesDisplayOnCapability=true and canUseExternalDisplay is false")
    func displayGatedAndDisabled() {
        let instance = makeInstance(status: .stopped)  // canUseExternalDisplay = false
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: true)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testPopOut", in: toolbar)?.isEnabled == false)
        #expect(item("testFullscreen", in: toolbar)?.isEnabled == false)
    }

    @Test("Display items enabled when gatesDisplayOnCapability=false regardless of status")
    func displayNotGatedAlwaysEnabled() {
        let instance = makeInstance(status: .stopped)
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testPopOut", in: toolbar)?.isEnabled == true)
        #expect(item("testFullscreen", in: toolbar)?.isEnabled == true)
    }

    // MARK: - Display Labels

    @Test("Pop Out label when displayMode is inline")
    func popOutLabelWhenInline() {
        let instance = makeInstance(status: .stopped)
        instance.displayMode = .inline
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testPopOut", in: toolbar)?.label == "Pop Out")
    }

    @Test("Pop In label when displayMode is popOut")
    func popInLabelWhenPopOut() {
        let instance = makeInstance(status: .stopped)
        instance.displayMode = .popOut
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testPopOut", in: toolbar)?.label == "Pop In")
    }

    @Test("Pop In label when displayMode is hidden (headless)")
    func popInLabelWhenHidden() {
        let instance = makeInstance(status: .stopped)
        instance.displayMode = .hidden
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testPopOut", in: toolbar)?.label == "Pop In")
    }

    @Test("Fullscreen label when not in fullscreen")
    func fullscreenLabelDefault() {
        let instance = makeInstance(status: .stopped)
        instance.displayMode = .inline
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testFullscreen", in: toolbar)?.label == "Fullscreen")
    }

    @Test("Exit Fullscreen label when in fullscreen")
    func exitFullscreenLabel() {
        let instance = makeInstance(status: .stopped)
        instance.displayMode = .fullscreen
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testFullscreen", in: toolbar)?.label == "Exit Fullscreen")
    }

    // MARK: - Settings Toggle

    @Test("Settings toggle is created as a plain NSToolbarItem (not a group)")
    func settingsToggleItemStructure() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testSettingsToggle"))
        #expect(item != nil)
        #expect(!(item is NSToolbarItemGroup))
        #expect(item?.label == "Show Settings")
    }

    @Test("Settings toggle is disabled when status has no active display")
    func settingsToggleDisabledWhenStopped() {
        let instance = makeInstance(status: .stopped)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let item = toolbar.items.first { $0.itemIdentifier.rawValue == "testSettingsToggle" }
        #expect(item?.isEnabled == false)
    }

    @Test("Settings toggle is enabled when status has active display")
    func settingsToggleEnabledWhenRunning() {
        let instance = makeInstance(status: .running)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let item = toolbar.items.first { $0.itemIdentifier.rawValue == "testSettingsToggle" }
        #expect(item?.isEnabled == true)
    }

    @Test("Settings toggle shows 'Show Settings' label when in display mode")
    func settingsToggleLabelInDisplayMode() {
        let instance = makeInstance(status: .running)
        instance.detailPaneMode = .display
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let item = toolbar.items.first { $0.itemIdentifier.rawValue == "testSettingsToggle" }
        #expect(item?.label == "Show Settings")
        #expect(item?.image?.accessibilityDescription == "Show Settings")
    }

    @Test("Settings toggle shows 'Hide Settings' label when in settings mode")
    func settingsToggleLabelInSettingsMode() {
        let instance = makeInstance(status: .running)
        instance.detailPaneMode = .settings
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let item = toolbar.items.first { $0.itemIdentifier.rawValue == "testSettingsToggle" }
        #expect(item?.label == "Hide Settings")
        #expect(item?.image?.accessibilityDescription == "Hide Settings")
    }

    @Test("Settings toggle is disabled when instance is nil")
    func settingsToggleDisabledWhenNilInstance() {
        let manager = makeManager(instance: nil)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let item = toolbar.items.first { $0.itemIdentifier.rawValue == "testSettingsToggle" }
        #expect(item?.isEnabled == false)
    }

    @Test("Settings toggle has a stable palette label")
    func settingsTogglePaletteLabel() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testSettingsToggle"))
        #expect(item?.paletteLabel == "Settings")
    }

    // MARK: - User-Customized Layouts

    @Test("updateToolbarItems tolerates a toolbar with no shared items")
    func updateWithAllItemsRemoved() {
        let instance = makeInstance(status: .running)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager, defaultItems: [])

        manager.updateToolbarItems(in: toolbar)

        #expect(toolbar.items.isEmpty)
    }

    @Test("updateToolbarItems still updates present items when others were removed")
    func updateWithPartialItemSet() {
        let instance = makeInstance(status: .running)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(
            manager: manager,
            defaultItems: [NSToolbarItem.Identifier("testLifecycle")]
        )

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        #expect(toolbar.items.count == 1)
        #expect(lifecycle?.subitems[1].isEnabled == true)  // pause (running)
        #expect(lifecycle?.subitems[2].isEnabled == true)  // stop (running)
    }
}

// MARK: - Test Helper

/// Minimal NSToolbarDelegate that delegates item creation to VMToolbarManager.
@MainActor
private final class ToolbarTestDelegate: NSObject, NSToolbarDelegate {
    let manager: VMToolbarManager
    /// When non-nil, overrides the default item set (simulates a user-customized layout).
    let defaultItems: [NSToolbarItem.Identifier]?

    init(manager: VMToolbarManager, defaultItems: [NSToolbarItem.Identifier]? = nil) {
        self.manager = manager
        self.defaultItems = defaultItems
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultItems ?? manager.sharedItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        manager.sharedItemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        manager.makeToolbarItem(for: itemIdentifier)
    }
}
