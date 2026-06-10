import AppKit
import Foundation
import Testing

@testable import Kernova

/// Behavioral tests for the pure-AppKit sidebar.
///
/// Covers the non-trivial logic that survives the SwiftUI→AppKit port: the
/// status-dot color mapping, the guest-agent indicator gating, the
/// drag-reorder index math, and the status-dependent context menu. Pure
/// layout/rendering is left to manual verification, per the project's testing
/// guidance.
@Suite("Sidebar Tests", .serialized)
@MainActor
struct SidebarViewControllerTests {
    private func makeViewModel() -> VMLibraryViewModel {
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.vmOrderKey)
        // Matches SidebarViewController.expandedSectionsKey; cleared so the group
        // defaults to expanded regardless of prior test/run state.
        UserDefaults.standard.removeObject(forKey: "KernovaSidebarExpandedSections")
        return VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService()
        )
    }

    private func makeInstance(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        status: VMStatus = .stopped
    ) -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: guestOS, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        instance.status = status
        return instance
    }

    private func titles(of menu: NSMenu) -> [String] {
        menu.items.map(\.title)
    }

    private func menuItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    private func findOutlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let found = findOutlineView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Status icon color

    @Test("statusDisplayNSColor maps each lifecycle state")
    func statusColorMapping() {
        let instance = makeInstance(status: .stopped)
        // Concrete gray (not `.secondaryLabelColor`) so the OS icon keeps its
        // stopped color on the selection highlight instead of inverting to white.
        #expect(instance.statusDisplayNSColor == .systemGray)

        instance.status = .running
        #expect(instance.statusDisplayNSColor == .systemGreen)

        instance.status = .error
        #expect(instance.statusDisplayNSColor == .systemRed)

        instance.status = .starting
        #expect(instance.statusDisplayNSColor == .systemOrange)
    }

    @Test("statusDisplayNSColor is orange for cold-paused and preparing")
    func statusColorColdPausedAndPreparing() {
        let coldPaused = makeInstance(status: .paused)  // no live VM ⇒ cold-paused
        #expect(coldPaused.isColdPaused)
        #expect(coldPaused.statusDisplayNSColor == .systemOrange)

        let preparing = makeInstance(status: .stopped)
        preparing.preparingState = VMInstance.PreparingState(operation: .cloning, task: Task {})
        #expect(preparing.statusDisplayNSColor == .systemOrange)
    }

    // MARK: - Agent indicator gating

    @Test("Agent indicator hidden for Linux guests")
    func agentHiddenForLinux() {
        let instance = makeInstance(guestOS: .linux)
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator shows .waiting for a fresh macOS VM")
    func agentWaitingVisibleForFreshMac() {
        let instance = makeInstance(guestOS: .macOS)
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: instance) == .waiting)
    }

    @Test("Agent indicator suppressed once the install nudge is dismissed")
    func agentSuppressedWhenDismissed() {
        let instance = makeInstance(guestOS: .macOS)
        instance.configuration.agentInstallNudgeDismissed = true
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator suppressed for a stopped VM that has seen the agent")
    func agentSuppressedWhenSeenAndStopped() {
        let instance = makeInstance(guestOS: .macOS)  // stopped, no live VM
        instance.configuration.lastSeenAgentVersion = "1.2.3"
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: instance) == nil)
    }

    // MARK: - Reorder index math

    @Test("reorderTarget maps drops and skips no-ops")
    func reorderTargetMapping() {
        // Move down / up: the proposed gap maps straight through.
        #expect(SidebarViewController.reorderTarget(sourceIndex: 0, proposedIndex: 3, count: 5) == 3)
        #expect(SidebarViewController.reorderTarget(sourceIndex: 4, proposedIndex: 1, count: 5) == 1)

        // Dropped into its own gap (above itself or just below) — no-op.
        #expect(SidebarViewController.reorderTarget(sourceIndex: 2, proposedIndex: 2, count: 5) == nil)
        #expect(SidebarViewController.reorderTarget(sourceIndex: 2, proposedIndex: 3, count: 5) == nil)

        // Dropped "on" the group row appends to the end.
        #expect(
            SidebarViewController.reorderTarget(
                sourceIndex: 0, proposedIndex: NSOutlineViewDropOnItemIndex, count: 5) == 5
        )
    }

    // MARK: - Context menu

    @Test("Context menu for a stopped VM offers Start and enables management")
    func contextMenuStopped() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .stopped)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Start"))
        #expect(!menuTitles.contains("Pause"))
        #expect(!menuTitles.contains("Stop"))
        #expect(menuItem("Rename", in: menu)?.isEnabled == true)
        #expect(menuItem("Clone", in: menu)?.isEnabled == true)
        #expect(menuItem("Move to Trash", in: menu)?.isEnabled == true)
    }

    @Test("Context menu for a running VM offers Pause/Stop/Suspend and disables editing")
    func contextMenuRunning() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .running)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Pause"))
        #expect(menuTitles.contains("Stop"))
        #expect(menuTitles.contains("Suspend"))
        #expect(!menuTitles.contains("Start"))
        #expect(menuItem("Clone", in: menu)?.isEnabled == false)
        #expect(menuItem("Move to Trash", in: menu)?.isEnabled == false)
        #expect(menuItem("Rename", in: menu)?.isEnabled == true)
    }

    @Test("Context menu for a cold-paused VM offers Discard Saved State, not Stop/Suspend")
    func contextMenuColdPaused() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .paused)  // no live VM ⇒ cold-paused
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Discard Saved State…"))
        #expect(menuTitles.contains("Resume"))
        #expect(!menuTitles.contains("Force Stop…"))
        #expect(!menuTitles.contains("Stop"))
        #expect(!menuTitles.contains("Suspend"))
    }

    @Test("Force Stop is the Option-alternate of Stop on a running VM (advanced options off)")
    func contextMenuForceStopIsOptionAlternate() {
        UserDefaults.standard.removeObject(forKey: "alwaysShowAdvancedOptions")
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .running)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        // Both rows exist in the item array; AppKit collapses them into one visible
        // "Stop" row and swaps in "Force Stop" only while Option is held.
        let stop = menuItem("Stop", in: menu)
        let forceStop = menuItem("Force Stop…", in: menu)
        #expect(stop != nil)
        #expect(forceStop != nil)
        // Keyless Option-reveal: the alternate carries [.option] and isAlternate, and
        // the primary's default [.command] mask is cleared so AppKit merges the pair.
        #expect(forceStop?.isAlternate == true)
        #expect(forceStop?.keyEquivalentModifierMask == [.option])
        #expect(stop?.keyEquivalentModifierMask == [])
    }

    @Test("Force Stop is a plain always-visible item when advanced options are on")
    func contextMenuForceStopVisibleWhenAdvanced() {
        UserDefaults.standard.set(true, forKey: "alwaysShowAdvancedOptions")
        defer { UserDefaults.standard.removeObject(forKey: "alwaysShowAdvancedOptions") }
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .running)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        let forceStop = menuItem("Force Stop…", in: menu)
        #expect(menuItem("Stop", in: menu) != nil)
        #expect(forceStop != nil)
        #expect(forceStop?.isAlternate == false)
    }

    @Test("Transient (starting) VM offers a standalone Force Stop, not an Option-alternate")
    func contextMenuForceStopStandaloneDuringTransition() {
        UserDefaults.standard.removeObject(forKey: "alwaysShowAdvancedOptions")
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .starting)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        // No graceful "Stop" to pair with, so "Force Stop" stands alone and stays
        // visible without holding Option.
        #expect(!menuTitles.contains("Stop"))
        #expect(menuItem("Force Stop…", in: menu)?.isAlternate == false)
    }

    @Test("Context menu for a preparing VM offers only Cancel and Show in Finder")
    func contextMenuPreparing() {
        let viewModel = makeViewModel()
        let instance = makeInstance()
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: Task {})
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Cancel Clone"))
        #expect(menuTitles.contains("Show in Finder"))
        #expect(!menuTitles.contains("Start"))
        #expect(!menuTitles.contains("Rename"))
    }

    // MARK: - Content-fit width

    @Test("contentWidth grows with name length")
    func contentWidthGrowsWithName() {
        let short = SidebarVMRowCellView.contentWidth(forName: "A", showsAgentAccessory: false)
        let long = SidebarVMRowCellView.contentWidth(
            forName: "A much longer virtual machine name", showsAgentAccessory: false)
        #expect(long > short)
    }

    @Test("contentWidth adds the agent accessory width and gap")
    func contentWidthAccessoryDelta() {
        let withoutBadge = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: false)
        let withBadge = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: true)
        // The accessory adds its 16pt width plus the small inter-element gap.
        #expect(withBadge - withoutBadge == Spacing.small + 16)
    }

    @Test("widthToFitLongestRow is nil with no VMs")
    func fitWidthNilWhenEmpty() {
        let viewModel = makeViewModel()
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        #expect(controller.widthToFitLongestRow() == nil)
    }

    @Test("widthToFitLongestRow grows with the longest VM name")
    func fitWidthTracksLongestName() {
        let shortModel = makeViewModel()
        shortModel.instances.append(makeInstance(name: "VM"))
        let shortController = SidebarViewController(viewModel: shortModel)
        shortController.loadViewIfNeeded()
        shortController.view.layoutSubtreeIfNeeded()

        let longModel = makeViewModel()
        longModel.instances.append(makeInstance(name: "An extremely long virtual machine name"))
        let longController = SidebarViewController(viewModel: longModel)
        longController.loadViewIfNeeded()
        longController.view.layoutSubtreeIfNeeded()

        guard let shortWidth = shortController.widthToFitLongestRow(),
            let longWidth = longController.widthToFitLongestRow()
        else {
            Issue.record("Expected a fit width for both controllers")
            return
        }
        #expect(longWidth > shortWidth)
    }

    // MARK: - View loading

    @Test("Outline view loads the group with its VM rows expanded")
    func outlineViewLoadsRows() {
        let viewModel = makeViewModel()
        viewModel.instances.append(makeInstance(name: "Alpha"))
        viewModel.instances.append(makeInstance(name: "Beta"))
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        guard let outline = findOutlineView(in: controller.view) else {
            Issue.record("Expected an NSOutlineView in the sidebar view tree")
            return
        }
        // One group row plus the two VM rows (group expanded by default).
        #expect(outline.numberOfRows == 3)
        #expect(outline.item(atRow: 0) is SidebarSection)
        #expect(outline.item(atRow: 1) is VMInstance)
    }
}
