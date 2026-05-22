import AppKit
import Foundation
import Testing
@testable import Kernova

@Suite("SidebarViewController Tests")
@MainActor
struct SidebarViewControllerTests {
    // MARK: - Test fixtures

    private func makeViewModel() -> VMLibraryViewModel {
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.vmOrderKey)
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
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

    private func addInstance(_ instance: VMInstance, to viewModel: VMLibraryViewModel) {
        viewModel.instances.append(instance)
    }

    // MARK: - Data source

    @Test("numberOfChildren returns 1 at root (the group)")
    func dataSourceRootCount() {
        let viewModel = makeViewModel()
        let controller = SidebarViewController(viewModel: viewModel)
        let count = controller.outlineView(NSOutlineView(), numberOfChildrenOfItem: nil)
        #expect(count == 1)
    }

    @Test("numberOfChildren of the group equals viewModel.instances.count")
    func dataSourceGroupCount() {
        let viewModel = makeViewModel()
        addInstance(makeInstance(name: "A"), to: viewModel)
        addInstance(makeInstance(name: "B"), to: viewModel)
        let controller = SidebarViewController(viewModel: viewModel)
        let count = controller.outlineView(NSOutlineView(), numberOfChildrenOfItem: SidebarGroupItem.shared)
        #expect(count == 2)
    }

    @Test("child(0, ofItem: nil) returns the group sentinel")
    func dataSourceRootChild() {
        let controller = SidebarViewController(viewModel: makeViewModel())
        let child = controller.outlineView(NSOutlineView(), child: 0, ofItem: nil)
        #expect(child as? SidebarGroupItem === SidebarGroupItem.shared)
    }

    @Test("child(i, ofItem: group) returns viewModel.instances[i]")
    func dataSourceGroupChild() {
        let viewModel = makeViewModel()
        let a = makeInstance(name: "A")
        let b = makeInstance(name: "B")
        addInstance(a, to: viewModel)
        addInstance(b, to: viewModel)
        let controller = SidebarViewController(viewModel: viewModel)
        let child0 = controller.outlineView(NSOutlineView(), child: 0, ofItem: SidebarGroupItem.shared)
        let child1 = controller.outlineView(NSOutlineView(), child: 1, ofItem: SidebarGroupItem.shared)
        #expect(child0 as? VMInstance === a)
        #expect(child1 as? VMInstance === b)
    }

    @Test("isItemExpandable returns true only for the group sentinel")
    func dataSourceExpandable() {
        let controller = SidebarViewController(viewModel: makeViewModel())
        let instance = makeInstance()
        #expect(controller.outlineView(NSOutlineView(), isItemExpandable: SidebarGroupItem.shared) == true)
        #expect(controller.outlineView(NSOutlineView(), isItemExpandable: instance) == false)
    }

    @Test("isGroupItem returns true only for the group sentinel")
    func dataSourceIsGroup() {
        let controller = SidebarViewController(viewModel: makeViewModel())
        let instance = makeInstance()
        #expect(controller.outlineView(NSOutlineView(), isGroupItem: SidebarGroupItem.shared) == true)
        #expect(controller.outlineView(NSOutlineView(), isGroupItem: instance) == false)
    }

    @Test("shouldSelectItem rejects the group, accepts instances")
    func dataSourceShouldSelect() {
        let controller = SidebarViewController(viewModel: makeViewModel())
        let instance = makeInstance()
        #expect(controller.outlineView(NSOutlineView(), shouldSelectItem: SidebarGroupItem.shared) == false)
        #expect(controller.outlineView(NSOutlineView(), shouldSelectItem: instance) == true)
    }

    // MARK: - Drag source guards

    @Test("pasteboardWriterForItem returns nil for the group sentinel")
    func dragWriterGroupSentinel() {
        let controller = SidebarViewController(viewModel: makeViewModel())
        let writer = controller.outlineView(NSOutlineView(), pasteboardWriterForItem: SidebarGroupItem.shared)
        #expect(writer == nil)
    }

    @Test("pasteboardWriterForItem returns nil for a preparing instance")
    func dragWriterPreparingGuard() {
        let viewModel = makeViewModel()
        let instance = makeInstance()
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
        addInstance(instance, to: viewModel)
        let controller = SidebarViewController(viewModel: viewModel)

        // Force the outline view to have a row for the instance so row(forItem:)
        // can resolve it to a non-negative row before the preparing guard fires.
        // The guard happens before that call, so we can pass any outline view.
        let writer = controller.outlineView(NSOutlineView(), pasteboardWriterForItem: instance)
        #expect(writer == nil)
    }

    // MARK: - External drop filtering

    @Test("importableBundleURLs filters non-bundle URLs")
    func importFiltersURLs() throws {
        let controller = SidebarViewController(viewModel: makeViewModel())
        let tempDir = FileManager.default.temporaryDirectory
        let bundle = tempDir.appendingPathComponent("Demo.\(VMStorageService.bundleExtension)")
        let other = tempDir.appendingPathComponent("README.txt")
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try "hi".data(using: .utf8)?.write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SidebarTestDrop"))
        pasteboard.clearContents()
        pasteboard.writeObjects([bundle as NSURL, other as NSURL])

        let urls = controller.importableBundleURLs(on: pasteboard)
        #expect(urls.contains(bundle))
        #expect(urls.contains(other) == false)
    }

    // MARK: - Context menu construction

    @Test("Context menu for stopped VM includes Start / Suspend not present")
    func contextMenuStopped() {
        let viewModel = makeViewModel()
        let instance = makeInstance()
        // .stopped is the default; canStart=true, canSave=false
        addInstance(instance, to: viewModel)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Start"))
        #expect(titles.contains("Suspend") == false)
        #expect(titles.contains("Pause") == false)
        #expect(titles.contains("Resume") == false)
        #expect(titles.contains("Rename"))
        #expect(titles.contains("Clone"))
        #expect(titles.contains("Show in Finder"))
        #expect(titles.contains("Move to Trash"))
    }

    @Test("Context menu for running VM includes Pause / Suspend / Stop, not Start")
    func contextMenuRunning() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .running)
        addInstance(instance, to: viewModel)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Start") == false)
        #expect(titles.contains("Pause"))
        #expect(titles.contains("Stop"))
        #expect(titles.contains("Suspend"))
        #expect(titles.contains("Force Stop") == false)
        // Running VMs cannot edit settings — rename/clone/delete reflect that
        let rename = menu.items.first { $0.title == "Rename" }
        let clone = menu.items.first { $0.title == "Clone" }
        let delete = menu.items.first { $0.title == "Move to Trash" }
        #expect(rename?.isEnabled == true)
        #expect(clone?.isEnabled == false)
        #expect(delete?.isEnabled == false)
    }

    @Test("Context menu for cold-paused VM includes Resume + Discard Saved State")
    func contextMenuColdPaused() {
        let viewModel = makeViewModel()
        // Without a live VZVirtualMachine, .paused → cold-paused
        let instance = makeInstance(status: .paused)
        addInstance(instance, to: viewModel)
        let controller = SidebarViewController(viewModel: viewModel)
        let menu = controller.buildContextMenu(for: instance)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Resume"))
        #expect(titles.contains("Discard Saved State"))
    }

    @Test("Context menu for preparing VM has Cancel + Show in Finder only")
    func contextMenuPreparing() {
        let viewModel = makeViewModel()
        let instance = makeInstance()
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)
        addInstance(instance, to: viewModel)
        let controller = SidebarViewController(viewModel: viewModel)
        let menu = controller.buildContextMenu(for: instance)
        let titles = menu.items.map { $0.title }
        #expect(titles == [VMInstance.PreparingOperation.cloning.cancelLabel, "Show in Finder"])
    }

    @Test("Context menu Stop variant: error status shows Start, not Force Stop")
    func contextMenuErrorStartable() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .error)
        addInstance(instance, to: viewModel)
        let controller = SidebarViewController(viewModel: viewModel)
        let menu = controller.buildContextMenu(for: instance)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Start"))
        #expect(titles.contains("Force Stop") == false)
    }
}
