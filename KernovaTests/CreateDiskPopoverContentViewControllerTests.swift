import Testing
import AppKit
@testable import Kernova

@Suite("CreateDiskPopoverContentViewController Tests")
@MainActor
struct CreateDiskPopoverContentViewControllerTests {
    @Test("loadView fits the CalloutStyle width")
    func fittingWidthMatchesStyle() {
        let vc = CreateDiskPopoverContentViewController(
            availableSizes: [10, 50, 100], defaultSizeInGB: 50)
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.view.fittingSize.width == CalloutStyle.width)
    }

    @Test("popup is populated from availableSizes with size-as-tag")
    func popupPopulation() {
        let sizes = [10, 25, 50, 100]
        let vc = CreateDiskPopoverContentViewController(
            availableSizes: sizes, defaultSizeInGB: 50)
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
        let vc = CreateDiskPopoverContentViewController(
            availableSizes: [10, 25, 50, 100], defaultSizeInGB: 50)
        vc.loadViewIfNeeded()

        #expect(vc.selectedSizeInGB == 50)
    }

    @Test("Cancel button invokes delegate's cancel method")
    func cancelInvokesDelegate() {
        let vc = CreateDiskPopoverContentViewController(
            availableSizes: [10, 50], defaultSizeInGB: 50)
        let delegate = MockCreateDiskDelegate()
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
        let vc = CreateDiskPopoverContentViewController(
            availableSizes: [10, 50, 100], defaultSizeInGB: 50)
        let delegate = MockCreateDiskDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        // Simulate the user picking a different size.
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
    private final class MockCreateDiskDelegate: CreateDiskPopoverContentViewControllerDelegate {
        var confirmedSizes: [Int] = []
        var cancelCount = 0

        func createDiskPopover(
            _ vc: CreateDiskPopoverContentViewController,
            didConfirmSizeInGB sizeInGB: Int
        ) {
            confirmedSizes.append(sizeInGB)
        }

        func createDiskPopoverDidCancel(_ vc: CreateDiskPopoverContentViewController) {
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
        // Skip NSPopUpButton instances; they're NSButton subclasses but
        // their `title` is the popup item, not a button label.
        if let button = view as? NSButton, !(view is NSPopUpButton), button.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(titled: title, in: subview) { return button }
        }
        return nil
    }
}
