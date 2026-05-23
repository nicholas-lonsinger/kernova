import Testing
import AppKit
@testable import Kernova

@Suite("MicrophonePermissionPopoverContentViewController Tests")
@MainActor
struct MicrophonePermissionPopoverContentViewControllerTests {
    @Test("loadView fits the CalloutStyle width")
    func fittingWidthMatchesStyle() {
        let vc = MicrophonePermissionPopoverContentViewController()
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.view.fittingSize.width == CalloutStyle.width)
    }

    @Test("contains the headline and 'How to enable' sub-headline")
    func headlineAndSubheadlinePresent() {
        let vc = MicrophonePermissionPopoverContentViewController()
        vc.loadViewIfNeeded()

        let labels = collectLabels(in: vc.view)
        #expect(labels.contains { $0.stringValue == "Microphone Permission" })
        #expect(labels.contains { $0.stringValue == "How to enable" })
    }

    @Test("contains an NSBox divider")
    func dividerPresent() {
        let vc = MicrophonePermissionPopoverContentViewController()
        vc.loadViewIfNeeded()

        let hasSeparator = findFirst(in: vc.view) { ($0 as? NSBox)?.boxType == .separator }
        #expect(hasSeparator != nil)
    }

    @Test("step labels apply a distinct font run for the emphasized phrase")
    func stepLabelsHaveDistinctFontRun() {
        let vc = MicrophonePermissionPopoverContentViewController()
        vc.loadViewIfNeeded()

        let expected = [
            "1. Open System Settings",
            "2. Go to Privacy & Security → Microphone",
            "3. Enable the toggle for Kernova",
        ]
        for stepText in expected {
            let label = collectLabels(in: vc.view).first {
                $0.attributedStringValue.string == stepText
            }
            guard let label else {
                Issue.record("Expected a step label with text '\(stepText)'")
                continue
            }
            // Two distinct .font runs proves the prefix and the emphasized
            // phrase carry different fonts (one regular, one bold). Avoids
            // the brittleness of name-comparing system fonts directly.
            #expect(
                countFontRuns(in: label.attributedStringValue) == 2,
                "Step '\(stepText)' should have prefix + bold portions as distinct font runs"
            )
        }
    }

    @Test("body and step labels are non-selectable")
    func bodyAndStepsAreNonSelectable() {
        let vc = MicrophonePermissionPopoverContentViewController()
        vc.loadViewIfNeeded()

        let labels = collectLabels(in: vc.view)
        for label in labels {
            #expect(!label.isSelectable, "Label '\(label.stringValue)' should not be selectable")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func collectLabels(in view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let field = view as? NSTextField { out.append(field) }
        for subview in view.subviews { out.append(contentsOf: collectLabels(in: subview)) }
        return out
    }

    @MainActor
    private func findFirst(in view: NSView, where predicate: (NSView) -> Bool) -> NSView? {
        if predicate(view) { return view }
        for subview in view.subviews {
            if let match = findFirst(in: subview, where: predicate) { return match }
        }
        return nil
    }

    /// Counts the number of distinct `.font`-attribute runs in `attributed`.
    private func countFontRuns(in attributed: NSAttributedString) -> Int {
        var count = 0
        attributed.enumerateAttribute(
            .font, in: NSRange(location: 0, length: attributed.length), options: []
        ) { _, _, _ in
            count += 1
        }
        return count
    }
}
