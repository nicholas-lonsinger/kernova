import AppKit
import Foundation
import Testing
@testable import Kernova

/// Targeted tests for ``SidebarRowView`` — specifically the row-reuse
/// rename-state restoration introduced in response to PR review feedback.
@Suite("SidebarRowView")
@MainActor
struct SidebarRowViewTests {
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

    private func makeInstance(name: String = "Test VM") -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: .stopped)
    }

    @Test("configure(_:) restores rename mode when activeRename matches the bound instance")
    func configureRestoresRenameOnReuse() {
        let viewModel = makeViewModel()
        let instance = makeInstance(name: "Sequoia")
        viewModel.instances.append(instance)
        viewModel.activeRename = .sidebar(instance.id)

        let row = SidebarRowView(viewModel: viewModel)
        row.configure(instance)

        #expect(row.isInRenameModeForTesting == true)
    }

    @Test("configure(_:) leaves the row in label mode when activeRename is nil")
    func configureStaysInLabelModeWhenNoRename() {
        let viewModel = makeViewModel()
        let instance = makeInstance(name: "Stopped VM")
        viewModel.instances.append(instance)
        // activeRename stays nil

        let row = SidebarRowView(viewModel: viewModel)
        row.configure(instance)

        #expect(row.isInRenameModeForTesting == false)
    }

    @Test("configure(_:) exits rename mode when activeRename moves to a different VM")
    func configureExitsRenameWhenActiveRenameMoves() {
        let viewModel = makeViewModel()
        let instanceA = makeInstance(name: "A")
        let instanceB = makeInstance(name: "B")
        viewModel.instances.append(instanceA)
        viewModel.instances.append(instanceB)

        // Start renaming A; row is bound to A and entered rename mode.
        viewModel.activeRename = .sidebar(instanceA.id)
        let row = SidebarRowView(viewModel: viewModel)
        row.configure(instanceA)
        #expect(row.isInRenameModeForTesting == true)

        // Active rename moves to B; the row gets rebound to B during reuse.
        // The row was renaming for A; configure(B) should exit (stale A
        // edits shouldn't apply to B), then re-enter because activeRename
        // now matches B.
        viewModel.activeRename = .sidebar(instanceB.id)
        row.configure(instanceB)
        #expect(row.isInRenameModeForTesting == true)
    }

    @Test("configure(_:) leaves rename mode when active rename clears")
    func configureExitsRenameWhenActiveRenameCleared() {
        let viewModel = makeViewModel()
        let instance = makeInstance(name: "Demo")
        viewModel.instances.append(instance)

        // Start with rename active.
        viewModel.activeRename = .sidebar(instance.id)
        let row = SidebarRowView(viewModel: viewModel)
        row.configure(instance)
        #expect(row.isInRenameModeForTesting == true)

        // Clear the active rename and re-bind the same instance.
        viewModel.activeRename = nil
        row.configure(instance)
        #expect(row.isInRenameModeForTesting == false)
    }
}
