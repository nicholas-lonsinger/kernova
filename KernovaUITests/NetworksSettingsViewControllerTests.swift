import AppKit
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// The Settings window's Networks pane over a network list Kernova can't read.
@Suite("Networks Settings Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct NetworksSettingsViewControllerTests {
    private let preferences = makeTestPreferences()

    /// The pane as the tab container shows it.
    private func makePane(_ viewModel: VMLibraryViewModel) -> NetworksSettingsViewController {
        let pane = NetworksSettingsViewController(viewModel: viewModel)
        pane.loadViewIfNeeded()
        pane.refreshContent()
        pane.viewWillAppear()
        return pane
    }

    // MARK: - Presence

    @Test("A network list Kernova can't read shows as unreadable, offers the check, and takes no change")
    func anUnreadableListShowsItsState() throws {
        let scratch = TestScratchDirectory(prefix: "NetworksSettingsUnreadable")
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let fileURL = scratch.url.appendingPathComponent("Networks.json")
        let bytes = Data("not json".utf8)
        try bytes.write(to: fileURL)
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: VirtualizationHost(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            localImageInspector: LocalRestoreImageInspector(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            bridgedInterfaces: HostBridgedInterfaceProvider(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: makeTestDownloadsDirectory(),
            preferences: preferences,
            vmnetNetworks: VmnetNetworkService.scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            networks: VMNetworkDirectory(fileURL: fileURL),
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(), bundleProducts: .testing)
        var checks = 0
        viewModel.onShowConfigCheck = { _ in checks += 1 }

        let pane = makePane(viewModel)

        #expect(pane.networks.isEmpty)
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
        }
        let addRemove = try #require(find(NSSegmentedControl.self, in: pane.view).first)
        #expect(!addRemove.isEnabled(forSegment: 0))
        #expect(!addRemove.isEnabled(forSegment: 1))
        let check = try #require(
            find(NSButton.self, in: pane.view).first { $0.title == "Check Config Files\u{2026}" })
        #expect(check.isHiddenOrHasHiddenAncestor == false)
        check.performClick(nil)
        #expect(checks == 1)

        let error = try #require(throws: CommandError.self) {
            try pane.create(name: "Lab", kind: .nat)
        }
        #expect(
            error.message
                == "Kernova can\u{2019}t read its list of networks. Choose File > Check Config Files\u{2026} to review it."
        )
        #expect(try Data(contentsOf: fileURL) == bytes)
    }
}
