import AppKit
@testable import KernovaUI
import Testing

@Suite("DiskSizePopoverContentViewController Tests", .caseScoped)
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

        let popup = firstSubview(NSPopUpButton.self, in: vc.view)
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

    @Test("Cancel button fires onCancel")
    func cancelFiresCallback() {
        let vc = make(headline: "X", caption: "Y", sizes: [10, 50], defaultGB: 50)
        var confirmedSizes: [Int] = []
        var cancelCount = 0
        vc.onConfirm = { confirmedSizes.append($0) }
        vc.onCancel = { cancelCount += 1 }
        vc.loadViewIfNeeded()

        guard let cancelButton = findButton(titled: "Cancel", in: vc.view) else {
            Issue.record("Expected a Cancel NSButton")
            return
        }
        cancelButton.performClick(nil)

        #expect(cancelCount == 1)
        #expect(confirmedSizes.isEmpty)
    }

    @Test("Create button fires onConfirm with the popup-selected size")
    func createFiresCallbackWithSelectedSize() {
        let vc = make(headline: "X", caption: "Y", sizes: [10, 50, 100], defaultGB: 50)
        var confirmedSizes: [Int] = []
        var cancelCount = 0
        vc.onConfirm = { confirmedSizes.append($0) }
        vc.onCancel = { cancelCount += 1 }
        vc.loadViewIfNeeded()

        let popup = firstSubview(NSPopUpButton.self, in: vc.view)
        popup?.selectItem(withTag: 100)

        guard let createButton = findButton(titled: "Create", in: vc.view) else {
            Issue.record("Expected a Create NSButton")
            return
        }
        createButton.performClick(nil)

        #expect(confirmedSizes == [100])
        #expect(cancelCount == 0)
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
}
