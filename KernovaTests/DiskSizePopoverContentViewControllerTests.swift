import Testing
import AppKit
@testable import Kernova

@Suite("DiskSizePopoverContentViewController Tests")
@MainActor
struct DiskSizePopoverContentViewControllerTests {
    @Test("loadView fits the CalloutStyle width")
    func fittingWidthMatchesStyle() {
        let vc = make(headline: "X", caption: "Y", sizes: [10, 50, 100], defaultGB: 50)
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.view.fittingSize.width == CalloutStyle.width)
    }

    @Test("popup is populated from availableSizes with size-as-tag")
    func popupPopulation() {
        let sizes = [10, 25, 50, 100]
        let vc = make(headline: "X", caption: "Y", sizes: sizes, defaultGB: 50)
        vc.loadViewIfNeeded()

        let popup = findPopUpButton(in: vc.view)
        guard let popup else {
            Issue.record("Expected an NSPopUpButton in the loaded view")
            return
        }
        #expect(popup.numberOfItems == sizes.count)
        let tags = (0..<popup.numberOfItems).map { popup.item(at: $0)?.tag ?? -1 }
        #expect(tags == sizes)
    }

    @Test("default selection matches defaultSizeInGB when present in availableSizes")
    func defaultSelectionApplied() {
        let vc = make(headline: "X", caption: "Y", sizes: [10, 25, 50, 100], defaultGB: 50)
        vc.loadViewIfNeeded()
        #expect(vc.selectedSizeInGB == 50)
    }

    @Test("headline and caption render the supplied strings")
    func headlineAndCaptionRender() {
        let vc = make(
            headline: "Create New Removable Disk",
            caption: "A wordy explanation about what will be created and where.",
            sizes: [10, 50], defaultGB: 50
        )
        vc.loadViewIfNeeded()

        guard let stack = vc.view.subviews.first as? NSStackView else {
            Issue.record("Expected NSStackView as the first container subview")
            return
        }
        let labels = stack.arrangedSubviews.compactMap { $0 as? NSTextField }
        #expect(labels.contains { $0.stringValue == "Create New Removable Disk" })
        #expect(
            labels.contains {
                $0.stringValue == "A wordy explanation about what will be created and where."
            }
        )
    }

    @Test("Cancel button invokes delegate's cancel method")
    func cancelInvokesDelegate() {
        let vc = make(headline: "X", caption: "Y", sizes: [10, 50], defaultGB: 50)
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        guard let cancelButton = findButton(titled: "Cancel", in: vc.view) else {
            Issue.record("Expected a Cancel NSButton")
            return
        }
        cancelButton.performClick(nil)

        #expect(delegate.cancelCount == 1)
        #expect(delegate.confirmedSizes.isEmpty)
    }

    @Test("Create button invokes delegate with the popup-selected size")
    func createInvokesDelegateWithSelectedSize() {
        let vc = make(headline: "X", caption: "Y", sizes: [10, 50, 100], defaultGB: 50)
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        let popup = findPopUpButton(in: vc.view)
        popup?.selectItem(withTag: 100)

        guard let createButton = findButton(titled: "Create", in: vc.view) else {
            Issue.record("Expected a Create NSButton")
            return
        }
        createButton.performClick(nil)

        #expect(delegate.confirmedSizes == [100])
        #expect(delegate.cancelCount == 0)
    }

    // MARK: - Helpers

    @MainActor
    private func make(
        headline: String, caption: String, sizes: [Int], defaultGB: Int
    ) -> DiskSizePopoverContentViewController {
        DiskSizePopoverContentViewController(
            headline: headline,
            caption: caption,
            availableSizes: sizes,
            defaultSizeInGB: defaultGB
        )
    }

    @MainActor
    private final class MockDelegate: DiskSizePopoverContentViewControllerDelegate {
        var confirmedSizes: [Int] = []
        var cancelCount = 0

        func diskSizePopover(
            _ vc: DiskSizePopoverContentViewController,
            didConfirmSizeInGB sizeInGB: Int
        ) {
            confirmedSizes.append(sizeInGB)
        }

        func diskSizePopoverDidCancel(_ vc: DiskSizePopoverContentViewController) {
            cancelCount += 1
        }
    }

    @MainActor
    private func findPopUpButton(in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton { return popup }
        for subview in view.subviews {
            if let popup = findPopUpButton(in: subview) { return popup }
        }
        return nil
    }

    @MainActor
    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, !(view is NSPopUpButton), button.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(titled: title, in: subview) { return button }
        }
        return nil
    }
}
