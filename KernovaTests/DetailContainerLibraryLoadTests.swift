import AppKit
import Testing
import Foundation
@testable import Kernova

/// The detail pane across the library's empty-until-read interval. The app now
/// presents its window before the library has been read, so the pane has to
/// distinguish "no VMs" from "no VMs *yet*".
@Suite("DetailContainer library-load state", .serialized, .admissionGated)
@MainActor
struct DetailContainerLibraryLoadTests {
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.detail-load")

    private func makeViewModel(storageService: MockVMStorageService = MockVMStorageService())
        -> VMLibraryViewModel
    {
        VMLibraryViewModel(
            storageService: storageService,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences
        )
    }

    /// Hosts the container in a window and runs the appearance pass that builds
    /// its content and arms its observation, as the split view controller does.
    private func present(_ controller: DetailContainerViewController) -> NSWindow {
        controller.loadViewIfNeeded()
        let window = showInTestWindow(controller.view, size: NSSize(width: 900, height: 600))
        controller.viewDidAppear()
        return window
    }

    /// Runs after every main-actor task already queued, so an `ObservationLoop`
    /// wake-up enqueued by the mutation under test has been applied.
    ///
    /// `ObservationLoop` applies through `Task { @MainActor … }` enqueued
    /// synchronously from the mutation, so a task enqueued afterwards lands
    /// behind it — a deterministic hand-off, not a poll or a settle delay.
    private func drainMainActor() async {
        await Task { @MainActor in }.value
    }

    private func hasEmptyState(_ controller: DetailContainerViewController) -> Bool {
        func search(_ view: NSView) -> Bool {
            if view is DetailEmptyStateView { return true }
            return view.subviews.contains(where: search)
        }
        return search(controller.view)
    }

    private func storageHoldingOneVM() -> (MockVMStorageService, VMConfiguration) {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Library VM", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config
        return (storage, config)
    }

    @Test("The no-VM empty state is withheld until the library has been read")
    func emptyStateWithheldBeforeLoad() {
        let (storage, _) = storageHoldingOneVM()
        let viewModel = makeViewModel(storageService: storage)
        let controller = DetailContainerViewController(viewModel: viewModel)
        let window = present(controller)
        defer { window.close() }

        // The library holds a VM that simply hasn't been read yet, so "No Virtual
        // Machine Selected" — and its New Virtual Machine button — would be a
        // false claim the user can act on.
        #expect(viewModel.hasLoadedLibrary == false)
        #expect(hasEmptyState(controller) == false)
    }

    @Test("A library that reads back empty reaches the no-VM empty state")
    func emptyStateShownAfterEmptyLoad() async {
        let viewModel = makeViewModel()
        let controller = DetailContainerViewController(viewModel: viewModel)
        let window = present(controller)
        defer { window.close() }
        #expect(hasEmptyState(controller) == false)

        await viewModel.loadVMs()
        await drainMainActor()

        // Load completion is the only change here — an empty library leaves
        // `instances` and `selectedID` exactly as they were — so this pins the
        // pane's observation of it. Tracking only the instance list would strand
        // the pane blank for the whole session.
        #expect(viewModel.hasLoadedLibrary == true)
        #expect(hasEmptyState(controller) == true)
    }

    @Test("A loaded VM replaces the withheld state with its detail content")
    func detailShownAfterPopulatedLoad() async {
        let (storage, config) = storageHoldingOneVM()
        let viewModel = makeViewModel(storageService: storage)
        let controller = DetailContainerViewController(viewModel: viewModel)
        let window = present(controller)
        defer { window.close() }

        await viewModel.loadVMs()
        await drainMainActor()

        #expect(viewModel.selectedID == config.id)
        #expect(viewModel.instances.map(\.name) == ["Library VM"])
        #expect(hasEmptyState(controller) == false)
    }
}
