import AppKit
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// Behavior tests for the Clipboard settings pane.
///
/// The pane's job is to make the paste ceiling selectable *and* legible: the
/// popup has to reflect and write the stored value, and the estimate line has to
/// track the selection rather than freeze on the value it first rendered.
@Suite("Clipboard Settings Tests", .serialized)
@MainActor
struct ClipboardSettingsViewControllerTests {
    private let preferences: AppPreferences

    init() {
        self.preferences = makeEphemeralPreferences(suiteName: "test.kernova.clipboard-settings")
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

    /// Builds the pane and runs the appear-time layout the way
    /// NSTabViewController does at tab-switch time.
    private func makeLaidOutController() -> ClipboardSettingsViewController {
        let controller = ClipboardSettingsViewController(
            preferences: preferences, viewModel: makeViewModel())
        _ = controller.view
        controller.viewWillAppear()
        controller.view.setFrameSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func popUp(in controller: ClipboardSettingsViewController) throws -> NSPopUpButton {
        try #require(findPopUpButton(in: controller.view))
    }

    // MARK: - The ladder

    @Test("the popup offers every ceiling, marking the derived default")
    func popUpOffersEveryChoice() throws {
        let controller = makeLaidOutController()
        let popUp = try popUp(in: controller)

        #expect(popUp.numberOfItems == ClipboardPasteLimit.choices.count)
        #expect(
            popUp.itemTitles
                == ClipboardPasteLimit.choices.map {
                    ClipboardSettingsViewController.itemTitle(for: $0)
                })
        // Exactly one stop carries the recommendation, and it is the derived one.
        let recommended = popUp.itemTitles.filter { $0.contains("Recommended") }
        #expect(recommended == ["2 GB (Recommended)"])
    }

    @Test("the popup opens on the stored ceiling, not the first one")
    func popUpSelectsTheStoredCeiling() throws {
        let raised = 16 * 1024 * 1024 * 1024
        preferences.clipboardMaxPasteBytes = raised

        let controller = makeLaidOutController()
        let popUp = try popUp(in: controller)

        #expect(popUp.selectedItem?.representedObject as? Int == raised)
    }

    @Test("selecting a ceiling writes it to preferences")
    func selectingWritesThePreference() throws {
        let controller = makeLaidOutController()
        let popUp = try popUp(in: controller)

        let lowered = 512 * 1024 * 1024
        popUp.selectItem(at: try #require(ClipboardPasteLimit.choices.firstIndex(of: lowered)))
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(preferences.clipboardMaxPasteBytes == lowered)
    }

    // MARK: - The explanation

    @Test("the pane states what the ceiling protects against, not just its size")
    func paneExplainsTheDeadline() {
        let controller = makeLaidOutController()

        // The failure the limit governs is the point of the pane — a bare byte
        // field would teach nothing.
        for fragment in ["60 seconds in Finder", "while the pasting app waits"] {
            let caption = findLabel(containing: fragment, in: controller.view)
            #expect(caption != nil, "caption '\(fragment)…' missing from the view tree")
            #expect(caption?.frame.height ?? 0 > 0, "caption '\(fragment)…' collapsed")
        }
    }

    @Test("the estimate line names the selected ceiling and its transfer time")
    func estimateNamesTheSelection() throws {
        let controller = makeLaidOutController()
        let popUp = try popUp(in: controller)

        // The default's estimate is on screen before anything is touched.
        #expect(findLabel(containing: "2 GB transfers in about 6 seconds", in: controller.view) != nil)

        let raised = 16 * 1024 * 1024 * 1024
        popUp.selectItem(at: try #require(ClipboardPasteLimit.choices.firstIndex(of: raised)))
        popUp.sendAction(popUp.action, to: popUp.target)

        // It recomputes rather than freezing on the value it first rendered.
        #expect(findLabel(containing: "16 GB transfers in about 45 seconds", in: controller.view) != nil)
        #expect(findLabel(containing: "2 GB transfers in about 6 seconds", in: controller.view) == nil)
    }

    @Test("the estimate quotes the measured throughput it divides by")
    func estimateQuotesTheMeasuredThroughput() {
        let text = ClipboardSettingsViewController.estimateText(
            for: ClipboardPasteLimit.defaultBytes)
        #expect(
            text.contains(
                ClipboardPasteLimit.displayLimit(
                    ClipboardPasteLimit.measuredThroughputBytesPerSecond)))
    }
}

/// Searches the view subtree depth-first for its first pop-up button.
@MainActor
private func findPopUpButton(in root: NSView) -> NSPopUpButton? {
    if let popUp = root as? NSPopUpButton { return popUp }
    for subview in root.subviews {
        if let found = findPopUpButton(in: subview) { return found }
    }
    return nil
}
