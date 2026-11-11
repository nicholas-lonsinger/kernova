import Cocoa
import KernovaAgentCore
import KernovaAgentHost
import KernovaKit
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("VMToolbarManager Tests", .caseScoped, .scopedWindows)
@MainActor
struct VMToolbarManagerTests {
    // MARK: - Factories

    private let preferences = makeTestPreferences()

    /// The library behind the capability catalog every manager reads — the
    /// settle checks (`isBusy`) resolve through it and its lifecycle.
    private func makeLibrary(
        virtualization: any VirtualizationProviding = MockVirtualizationService()
    ) -> (library: VMLibrary, lifecycle: VMLifecycleCoordinator) {
        let lifecycle = makeTestLifecycle(virtualization: virtualization)
        let library = makeWiredLibrary(lifecycle: lifecycle, preferences: preferences)
        return (library, lifecycle)
    }

    private func makeInstance(
        phase: VMLifecyclePhase = .stopped, clipboardSharing: Bool = true
    ) -> VMInstance {
        VMInstanceFixture.make(phase: phase) { $0.clipboardSharingEnabled = clipboardSharing }
    }

    private func makeManager(
        instance: VMInstance? = nil,
        library: VMLibrary? = nil,
        gatesDisplayOnCapability: Bool = true,
        includeSettingsToggle: Bool = true,
        selection: (() -> VMInstance?)? = nil
    ) -> VMToolbarManager {
        VMToolbarManager(
            configuration: .init(
                lifecycleID: NSToolbarItem.Identifier("testLifecycle"),
                stopAnywayID: NSToolbarItem.Identifier("testStopAnyway"),
                restartAnywayID: NSToolbarItem.Identifier("testRestartAnyway"),
                saveStateID: NSToolbarItem.Identifier("testSaveState"),
                takeSnapshotID: NSToolbarItem.Identifier("testTakeSnapshot"),
                copyToMacID: NSToolbarItem.Identifier("testCopyToMac"),
                copyToGuestID: NSToolbarItem.Identifier("testCopyToGuest"),
                popOutID: NSToolbarItem.Identifier("testPopOut"),
                fullscreenID: NSToolbarItem.Identifier("testFullscreen"),
                settingsToggleID: includeSettingsToggle ? NSToolbarItem.Identifier("testSettingsToggle") : nil,
                gatesDisplayOnCapability: gatesDisplayOnCapability
            ),
            capabilities: VMCapabilityCatalog(library: library ?? makeLibrary().library),
            instanceProvider: selection ?? { instance }
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
        let window = makeTestWindow(
            styleMask: [.titled], contentSize: NSSize(width: 400, height: 300))
        window.toolbar = toolbar
        return (toolbar, window, delegate)
    }

    // MARK: - Item Creation

    @Test("makeToolbarItem returns the lifecycle group: Start, Pause, Stop, Restart")
    func lifecycleGroupStructure() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testLifecycle"))
        let group = item as? NSToolbarItemGroup
        #expect(group != nil)
        #expect(group?.subitems.map(\.label) == ["Start", "Pause", "Stop", "Restart"])
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

    @Test("Take Snapshot is enabled wherever Suspend is, and on a stopped VM too")
    func takeSnapshotCoversStoppedAsWell() {
        for (phase, expected) in [
            (VMLifecyclePhase.running(sessionID: UUID()), true),
            (.livePaused(sessionID: UUID()), true), (.stopped, true),
            (
                .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
                false
            ),
        ] {
            let instance = makeInstance(phase: phase)
            let manager = makeManager(instance: instance)
            let (toolbar, _, _) = makeToolbar(manager: manager)

            manager.updateToolbarItems(in: toolbar)

            #expect(
                item("testTakeSnapshot", in: toolbar)?.isEnabled == expected,
                "phase \(phase)")
        }
        // Suspend keeps its own, narrower gate.
        let stopped = makeInstance(phase: .stopped)
        let manager = makeManager(instance: stopped)
        let (toolbar, _, _) = makeToolbar(manager: manager)
        manager.updateToolbarItems(in: toolbar)
        #expect(item("testSaveState", in: toolbar)?.isEnabled == false)
    }

    @Test("The toolbar's own observation dims Take Snapshot when an operation starts settling")
    func takeSnapshotDisabledWhileSettling() async throws {
        let suspending = SuspendingMockVirtualizationService()
        suspending.shouldSuspendOnResume = true
        let (library, lifecycle) = makeLibrary(virtualization: suspending)
        let instance = library.admitFixture(phase: .livePaused(sessionID: UUID())) {
            $0.clipboardSharingEnabled = true
        }
        let manager = makeManager(instance: instance, library: library)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        // The loop both hosts run, verbatim. Every item sets
        // `autovalidates = false`, so this is the *only* thing that refreshes
        // them — driving `updateToolbarItems(in:)` directly would pass whether
        // or not the settle signal is in the tracked read set.
        let applied = AsyncGate()
        let loop = observeRecurring(
            track: { manager.trackItemState() },
            apply: {
                manager.updateToolbarItems(in: toolbar)
                applied.notify()
            })
        defer { loop.cancel() }

        manager.updateToolbarItems(in: toolbar)
        #expect(item("testTakeSnapshot", in: toolbar)?.isEnabled == true)

        // The resume presents `.paused` while it runs, so the phase it started
        // from still names a capture — one requested now is refused as busy,
        // so the button has to go dim rather than error on click.
        let resume = try lifecycle.launchResume(instance)
        await suspending.waitUntilSuspended()
        try await applied.wait { item("testTakeSnapshot", in: toolbar)?.isEnabled == false }

        #expect(
            VMAdmission.settledCaptureMode(phase: instance.phase, facts: instance.admissionFacts)
                == .live)
        #expect(item("testTakeSnapshot", in: toolbar)?.isEnabled == false)

        suspending.resumeSuspended()
        try await resume.value()
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

    @Test(
        "Stop Anyway and Restart Anyway are offered in the palette and left out of the default set",
        arguments: [
            ("testStopAnyway", "Stop Anyway", NSStringFromSelector(#selector(AppDelegate.stopAnywayVM(_:)))),
            (
                "testRestartAnyway", "Restart Anyway",
                NSStringFromSelector(#selector(AppDelegate.restartAnywayVM(_:)))
            ),
        ])
    func anywayItemsArePaletteOnly(identifier: String, label: String, action: String) {
        let manager = makeManager()
        let anyway = NSToolbarItem.Identifier(identifier)
        #expect(manager.sharedItemIdentifiers.contains(anyway))
        #expect(!manager.defaultItemIdentifiers.contains(anyway))
        let item = manager.makeToolbarItem(for: anyway)
        #expect(item?.label == label)
        #expect(item?.action.map(NSStringFromSelector) == action)
        #expect(item?.isBordered == true)
    }

    @Test(
        "Stop Anyway and Restart Anyway are greyed out unless the guest's agents offer them, and the lifecycle group is unchanged",
        arguments: [true, false])
    func anywayEnablement(offered: Bool) {
        let instance = makeInstance(phase: .running(sessionID: UUID()))
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(
                peers: [], features: FeatureStatus.merge([]),
                powerIgnoringApps: offered ? .agent(.systemPeer) : .absent(.noAgent)))
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(
            manager: manager,
            defaultItems: ["testLifecycle", "testStopAnyway", "testRestartAnyway"].map {
                NSToolbarItem.Identifier($0)
            })

        manager.updateToolbarItems(in: toolbar)

        for identifier in ["testStopAnyway", "testRestartAnyway"] {
            let anyway = toolbar.items.first { $0.itemIdentifier.rawValue == identifier }
            #expect(anyway != nil, "\(identifier)")
            #expect(anyway?.isEnabled == offered, "\(identifier)")
        }
        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        #expect(lifecycle?.subitems.map { $0.label } == ["Start", "Pause", "Stop", "Restart"])
        #expect(lifecycle?.subitems[2].isEnabled == true)
        #expect(lifecycle?.subitems[3].isEnabled == true)
    }

    @Test("defaultItemIdentifiers omits the trailing space without a settings toggle")
    func defaultIdentifiersWithoutSettingsToggle() {
        let manager = makeManager(includeSettingsToggle: false)
        #expect(
            manager.defaultItemIdentifiers == [
                NSToolbarItem.Identifier("testLifecycle"),
                NSToolbarItem.Identifier("testSaveState"),
                NSToolbarItem.Identifier("testTakeSnapshot"),
                .space,
                NSToolbarItem.Identifier("testCopyToMac"),
                NSToolbarItem.Identifier("testCopyToGuest"),
                .space,
                NSToolbarItem.Identifier("testPopOut"),
                NSToolbarItem.Identifier("testFullscreen"),
            ])
    }

    // MARK: - Nil Instance

    @Test("Every item is disabled while an arrival is the selected row")
    func selectedArrivalDisablesEveryItem() async throws {
        let library = makeLibrary().library
        let gate = GatedStep()
        let arrival = library.beginGatedArrival(named: "Arriving", gate: gate)
        #expect(library.selectedID == arrival.id)
        let manager = makeManager(library: library, selection: { library.selectedInstance })
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(!toolbar.items.isEmpty)
        for item in toolbar.items {
            let controls = (item as? NSToolbarItemGroup)?.subitems ?? [item]
            #expect(
                controls.allSatisfy { !$0.isEnabled }, "\(item.itemIdentifier.rawValue) is enabled")
        }

        gate.release()
        await arrival.settle()
    }

    // MARK: - Clipboard commands

    private func clipboardButton(_ raw: String, in toolbar: NSToolbar) -> ClipboardToolbarButton? {
        item(raw, in: toolbar)?.view as? ClipboardToolbarButton
    }

    /// Has a console peer carry `instance`'s clipboard through its hub.
    private func carryClipboard(on instance: VMInstance) {
        let peer = PeerHandle(rawValue: 1)
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [], features: FeatureStatus.merge([]), consolePeers: [.clipboard: peer]))
        instance.hubClipboard.setConsolePeer(peer)
    }

    @Test(
        "Each clipboard command's item is a view-backed button sending its action down the responder chain",
        arguments: [
            ("testCopyToMac", "Copy to Mac", #selector(AppDelegate.copyGuestClipboardToMac(_:))),
            ("testCopyToGuest", "Copy to Guest", #selector(AppDelegate.copyMacClipboardToGuest(_:))),
        ])
    func clipboardItemStructure(raw: String, label: String, action: Selector) {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier(raw))
        #expect(item?.label == label)
        #expect(item?.paletteLabel == label)
        #expect(item?.autovalidates == false)
        let button = item?.view as? ClipboardToolbarButton
        #expect(button?.action == action)
        #expect(button?.target == nil)
    }

    /// Stands a running readout on `instance` moving `direction`, as a producer's operation would, returning the
    /// operation — the reporter holds only a weak reference, so the caller must keep it alive.
    private func publishProgress(
        transferred: UInt64, total: UInt64, direction: ClipboardProgressSnapshot.Direction, on instance: VMInstance
    ) -> ClipboardTransferOperation {
        let operation = ClipboardTransferOperation(
            gesture: .paste, direction: direction, peerName: instance.name, revealDelay: 0,
            clock: GatedEngineClock(), reporter: instance.clipboardTransfers)
        instance.clipboardTransfers.publish(
            from: operation,
            .running(
                ClipboardProgressSnapshot(
                    direction: direction, peerName: instance.name, currentItemName: nil,
                    filesCompleted: 0, fileCount: 1, bytesTransferred: transferred,
                    totalBytes: total, bytesPerSecond: nil, secondsRemaining: nil, gesture: .paste,
                    elapsedSeconds: 1), since: Date()))
        return operation
    }

    @Test(
        "A running transfer's bar shows on the button of its direction, and leaves once it ends",
        arguments: [
            (ClipboardProgressSnapshot.Direction.inbound, "testCopyToMac", "testCopyToGuest"),
            (.outbound, "testCopyToGuest", "testCopyToMac"),
        ])
    func clipboardBarFollowsDirection(direction: ClipboardProgressSnapshot.Direction, shown: String, hidden: String) {
        let instance = makeInstance(phase: .running(sessionID: UUID()))
        let operation = publishProgress(transferred: 25, total: 100, direction: direction, on: instance)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)
        manager.updateToolbarItems(in: toolbar)
        #expect(clipboardButton(shown, in: toolbar)?.transferFraction == 0.25)
        #expect(clipboardButton(hidden, in: toolbar)?.transferFraction == nil)

        instance.clipboardTransfers.retire(operation)
        manager.updateToolbarItems(in: toolbar)
        #expect(clipboardButton(shown, in: toolbar)?.transferFraction == nil)
    }

    // MARK: - Lifecycle Labels

    @Test("Play button shows 'Resume' for a VM holding a saved state")
    func playLabelResumeWhenPaused() throws {
        let instance = makeInstance(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        let playItem = lifecycle?.subitems[0]
        #expect(playItem?.label == "Resume")
    }

    // MARK: - Lifecycle Enable States

    @Test("Play (resume) and stop enabled when paused")
    func resumeStopEnabledWhenPaused() throws {
        let instance = makeInstance(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let lifecycle = toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup
        #expect(lifecycle?.subitems[0].isEnabled == true)  // resume
        #expect(lifecycle?.subitems[1].isEnabled == false)  // pause (already paused)
        #expect(lifecycle?.subitems[2].isEnabled == true)  // stop
    }

    /// The stop segment of a suspended VM discards its saved state, which no
    /// restart follows; everywhere else the two segments are one gate.
    @Test("Restart is enabled exactly where the stop segment offers Stop")
    func restartFollowsStop() throws {
        for (phase, expected) in [
            (PhaseFixture.settled(.running(sessionID: UUID())), true),
            (.settled(.livePaused(sessionID: UUID())), true),
            (.settled(.stopped), false),
            (.settled(.suspended), false),
            (.operating(.saving, from: .running(sessionID: UUID())), false),
            (.operating(.pausing, from: .running(sessionID: UUID())), true),
            (.operating(.forceStopping, from: .running(sessionID: UUID())), false),
        ] {
            let instance = makeInstance(phase: phase.phase)
            if case .settled(.suspended) = phase { try VMInstanceFixture.writeSaveFile(for: instance) }
            let manager = makeManager(instance: instance)
            let (toolbar, _, _) = makeToolbar(manager: manager)

            manager.updateToolbarItems(in: toolbar)

            let lifecycle = try #require(
                toolbar.items.first { $0.itemIdentifier.rawValue == "testLifecycle" } as? NSToolbarItemGroup)
            let stop = lifecycle.subitems[2]
            let offersStop = stop.isEnabled && stop.label == VMInstance.StopAction.stop.toolbarLabel
            #expect(offersStop == expected, "\(phase)")
            #expect(lifecycle.subitems[3].isEnabled == expected, "\(phase)")
        }
    }

    // MARK: - Display Item Gating

    @Test("Display items disabled when gatesDisplayOnCapability=true and canUseExternalDisplay is false")
    func displayGatedAndDisabled() {
        let instance = makeInstance(phase: .stopped)  // canUseExternalDisplay = false
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: true)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testPopOut", in: toolbar)?.isEnabled == false)
        #expect(item("testFullscreen", in: toolbar)?.isEnabled == false)
    }

    @Test("Display items enabled when gatesDisplayOnCapability=false regardless of status")
    func displayNotGatedAlwaysEnabled() {
        let instance = makeInstance(phase: .stopped)
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testPopOut", in: toolbar)?.isEnabled == true)
        #expect(item("testFullscreen", in: toolbar)?.isEnabled == true)
    }

    // MARK: - Display Labels

    @Test("Pop Out label when displayMode is inline")
    func popOutLabelWhenInline() {
        let instance = makeInstance(phase: .stopped)
        instance.displayMode = .inline
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testPopOut", in: toolbar)?.label == "Pop Out")
    }

    @Test("Pop In label when displayMode is popOut")
    func popInLabelWhenPopOut() {
        let instance = makeInstance(phase: .stopped)
        instance.displayMode = .popOut
        let manager = makeManager(instance: instance, gatesDisplayOnCapability: false)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        #expect(item("testPopOut", in: toolbar)?.label == "Pop In")
    }

    @Test("Exit Fullscreen label when in fullscreen")
    func exitFullscreenLabel() {
        let instance = makeInstance(phase: .stopped)
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

    @Test("Settings toggle shows 'Hide Settings' label when in settings mode")
    func settingsToggleLabelInSettingsMode() {
        let instance = makeInstance(phase: .running(sessionID: UUID()))
        instance.detailPaneMode = .settings
        let manager = makeManager(instance: instance)
        let (toolbar, _, _) = makeToolbar(manager: manager)

        manager.updateToolbarItems(in: toolbar)

        let item = toolbar.items.first { $0.itemIdentifier.rawValue == "testSettingsToggle" }
        #expect(item?.label == "Hide Settings")
        #expect(item?.image?.accessibilityDescription == "Hide Settings")
    }

    @Test("Settings toggle has a stable palette label")
    func settingsTogglePaletteLabel() {
        let manager = makeManager()
        let item = manager.makeToolbarItem(for: NSToolbarItem.Identifier("testSettingsToggle"))
        #expect(item?.paletteLabel == "Settings")
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
