import Testing
import Cocoa
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
        gatesDisplayOnCapability: Bool = true
    ) -> VMToolbarManager {
        VMToolbarManager(
            configuration: .init(
                lifecycleID: NSToolbarItem.Identifier("testLifecycle"),
                saveStateID: NSToolbarItem.Identifier("testSaveState"),
                clipboardID: NSToolbarItem.Identifier("testClipboard"),
                removableMediaID: NSToolbarItem.Identifier("testRemovableMedia"),
                displayID: NSToolbarItem.Identifier("testDisplay"),
                checksPreparing: checksPreparing,
                gatesDisplayOnCapability: gatesDisplayOnCapability
            ),
            instanceProvider: { instance }
        )
    }

    /// Creates an NSToolbar attached to a window so `toolbar.items` is populated via delegate callbacks.
    private func makeToolbar(manager: VMToolbarManager) -> (NSToolbar, NSWindow, ToolbarTestDelegate) {
        let delegate = ToolbarTestDelegate(manager: manager)
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

    @Test("makeToolbarItem returns save state group with 1 subitem")
    func saveStateGroupStructure() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testSaveState"))
        let group = item as? NSToolbarItemGroup
        #expect(group != nil)
        #expect(group?.subitems.count == 1)
        #expect(group?.label == "Save State")
    }

    @Test("makeToolbarItem returns display group with 2 subitems")
    func displayGroupStructure() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testDisplay"))
        let group = item as? NSToolbarItemGroup
        #expect(group != nil)
        #expect(group?.subitems.count == 2)
        #expect(group?.label == "Display")
    }

    @Test("makeToolbarItem returns nil for unknown identifier")
    func unknownIdentifierReturnsNil() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("unknown"))
        #expect(item == nil)
    }

    @Test("sharedItemIdentifiers contains all five identifiers")
    func sharedIdentifiers() {
        let manager = makeManager()
        #expect(manager.sharedItemIdentifiers.count == 5)
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testLifecycle")))
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testSaveState")))
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testClipboard")))
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testRemovableMedia")))
        #expect(manager.sharedItemIdentifiers.contains(NSToolbarItem.Identifier("testDisplay")))
    }

    // MARK: - Nil Instance

    @Test("All items disabled when instance is nil")
    func nilInstanceDisablesAll() {
        let manager = makeManager(instance: nil)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        let saveState = toolbar.items.first { $0.itemIdentifier.rawValue == "testSaveState" } as? NSToolbarItemGroup
        let display = toolbar.items.first { $0.itemIdentifier.rawValue == "testDisplay" } as? NSToolbarItemGroup

        #expect(lifecycle?.subitems.allSatisfy { !$0.isEnabled } == true)
        #expect(saveState?.subitems.first?.isEnabled == false)
        #expect(display?.subitems.allSatisfy { !$0.isEnabled } == true)
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
        #expect(lifecycle?.subitems[1].isEnabled == false) // pause
        #expect(lifecycle?.subitems[2].isEnabled == false) // stop
    }

    @Test("Pause and stop enabled when running")
    func pauseStopEnabledWhenRunning() {
        let instance = makeInstance(status: .running)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        #expect(lifecycle?.subitems[0].isEnabled == false) // play (can't start when running)
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
        #expect(lifecycle?.subitems[1].isEnabled == false) // pause (already paused)
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

        let saveState = toolbar.items.first { $0.itemIdentifier.rawValue == "testSaveState" } as? NSToolbarItemGroup
        #expect(saveState?.subitems.first?.isEnabled == true)
    }

    @Test("Save state disabled when stopped")
    func saveDisabledWhenStopped() {
        let instance = makeInstance(status: .stopped)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let saveState = toolbar.items.first { $0.itemIdentifier.rawValue == "testSaveState" } as? NSToolbarItemGroup
        #expect(saveState?.subitems.first?.isEnabled == false)
    }

    // MARK: - Display Group Gating

    @Test("Display items disabled when gatesDisplayOnCapability=true and canUseExternalDisplay is false")
    func displayGatedAndDisabled() {
        let instance = makeInstance(status: .stopped) // canUseExternalDisplay = false
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: true)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let display = toolbar.items.first { $0.itemIdentifier.rawValue == "testDisplay" } as? NSToolbarItemGroup
        #expect(display?.subitems[0].isEnabled == false)
        #expect(display?.subitems[1].isEnabled == false)
    }

    @Test("Display items enabled when gatesDisplayOnCapability=false regardless of status")
    func displayNotGatedAlwaysEnabled() {
        let instance = makeInstance(status: .stopped)
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let display = toolbar.items.first { $0.itemIdentifier.rawValue == "testDisplay" } as? NSToolbarItemGroup
        #expect(display?.subitems[0].isEnabled == true)
        #expect(display?.subitems[1].isEnabled == true)
    }

    // MARK: - Display Labels

    @Test("Pop Out label when displayMode is inline")
    func popOutLabelWhenInline() {
        let instance = makeInstance(status: .stopped)
        instance.displayMode = .inline
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let display = toolbar.items.first { $0.itemIdentifier.rawValue == "testDisplay" } as? NSToolbarItemGroup
        #expect(display?.subitems[0].label == "Pop Out")
    }

    @Test("Pop In label when displayMode is popOut")
    func popInLabelWhenPopOut() {
        let instance = makeInstance(status: .stopped)
        instance.displayMode = .popOut
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let display = toolbar.items.first { $0.itemIdentifier.rawValue == "testDisplay" } as? NSToolbarItemGroup
        #expect(display?.subitems[0].label == "Pop In")
    }

    @Test("Fullscreen label when not in fullscreen")
    func fullscreenLabelDefault() {
        let instance = makeInstance(status: .stopped)
        instance.displayMode = .inline
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let display = toolbar.items.first { $0.itemIdentifier.rawValue == "testDisplay" } as? NSToolbarItemGroup
        #expect(display?.subitems[1].label == "Fullscreen")
    }

    @Test("Exit Fullscreen label when in fullscreen")
    func exitFullscreenLabel() {
        let instance = makeInstance(status: .stopped)
        instance.displayMode = .fullscreen
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let display = toolbar.items.first { $0.itemIdentifier.rawValue == "testDisplay" } as? NSToolbarItemGroup
        #expect(display?.subitems[1].label == "Exit Fullscreen")
    }
}

// MARK: - Test Helper

/// Minimal NSToolbarDelegate that delegates item creation to VMToolbarManager.
@MainActor
private final class ToolbarTestDelegate: NSObject, NSToolbarDelegate {
    let manager: VMToolbarManager

    init(manager: VMToolbarManager) {
        self.manager = manager
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        manager.sharedItemIdentifiers
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
