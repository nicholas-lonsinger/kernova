import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// Layout tests for the Reminders settings pane.
///
/// The pane hugs its content when short and scrolls past a height cap. The
/// regression risk is the capped state: the pane's frame is fixed by the tab
/// controller, and a hug constraint that outranks the text's compression
/// resistance resolves the shortfall by collapsing every section header and
/// caption to zero height instead of scrolling.
@Suite("Reminders Settings Tests", .serialized)
@MainActor
struct RemindersSettingsViewControllerTests {
    private let preferences: AppPreferences

    init() {
        self.preferences = makeEphemeralPreferences(suiteName: "test.kernova.reminders-settings")
    }

    private func makeViewModel() -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences
        )
    }

    private func makeInstance(name: String) -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .macOS, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    /// Builds the pane with `vmCount` VMs and runs the appear-time layout the
    /// way NSTabViewController does: it reads `preferredContentSize` at switch
    /// time and sizes the pane's view to exactly that.
    private func makeLaidOutController(vmCount: Int) -> RemindersSettingsViewController {
        let viewModel = makeViewModel()
        for index in 1...vmCount {
            viewModel.instances.append(makeInstance(name: "VM \(index)"))
        }
        let controller = RemindersSettingsViewController(
            preferences: preferences, viewModel: viewModel)
        _ = controller.view
        controller.viewWillAppear()
        controller.view.setFrameSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func expectHeadersAndCaptionsVisible(in root: NSView) {
        for text in ["App Reminders", "Virtual Machine Reminders"] {
            let header = findLabel(withText: text, in: root)
            #expect(header != nil, "header '\(text)' missing from the view tree")
            if let header {
                #expect(header.frame.height > 0, "header '\(text)' collapsed: \(header.frame)")
            }
        }
        for fragment in [
            "Menu Bar Quit Reminder appears",
            "File Sharing Reminder appears",
            "stop its sidebar reminder",
            "Turns every reminder above back on",
            "managed separately",
        ] {
            let caption = findLabel(containing: fragment, in: root)
            #expect(caption != nil, "caption '\(fragment)…' missing from the view tree")
            if let caption {
                #expect(
                    caption.frame.height > 0, "caption '\(fragment)…' collapsed: \(caption.frame)")
            }
        }
    }

    @Test("A VM list past the height cap scrolls instead of collapsing the text")
    func cappedPaneScrollsAndKeepsText() throws {
        let controller = makeLaidOutController(vmCount: 9)
        defer { controller.viewDidDisappear() }

        expectHeadersAndCaptionsVisible(in: controller.view)

        // The content must keep its natural height and overflow the capped
        // pane — a squeezed document exactly matching the pane's height is the
        // collapse bug, not scrolling.
        let scrollView = try #require(controller.view as? NSScrollView)
        let documentView = try #require(scrollView.documentView)
        #expect(documentView.frame.height > scrollView.frame.height)
    }

    @Test("A short VM list hugs the content with the text laid out")
    func shortPaneHugsContentAndKeepsText() throws {
        let controller = makeLaidOutController(vmCount: 2)
        defer { controller.viewDidDisappear() }

        expectHeadersAndCaptionsVisible(in: controller.view)

        // Hugged: everything fits, so nothing scrolls.
        let scrollView = try #require(controller.view as? NSScrollView)
        let documentView = try #require(scrollView.documentView)
        #expect(documentView.frame.height <= scrollView.frame.height)
    }
}
