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

    // MARK: - Clipboard commands

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
}
