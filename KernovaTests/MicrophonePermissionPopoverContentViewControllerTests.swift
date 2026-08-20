import Testing
import AppKit
@testable import Kernova

@Suite("MicrophonePermissionPopoverContentViewController Tests", .admissionGated)
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

        let hasSeparator = firstSubview(NSBox.self, in: vc.view) { $0.boxType == .separator }
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

    @Test("offers an Open System Settings button alongside the manual steps")
    func openSettingsButtonPresent() {
        let vc = MicrophonePermissionPopoverContentViewController()
        vc.loadViewIfNeeded()

        #expect(findButton(titled: "Open System Settings", in: vc.view) != nil)
    }

    @Test("clicking Open System Settings opens the Microphone privacy pane")
    func openSettingsButtonOpensMicrophonePane() throws {
        let recorder = URLOpenRecorder(results: [true])
        let vc = MicrophonePermissionPopoverContentViewController(
            systemSettings: SystemSettingsLink(open: recorder.open))
        vc.loadViewIfNeeded()

        let button = try #require(findButton(titled: "Open System Settings", in: vc.view))
        button.performClick(nil)

        #expect(recorder.opened == [SystemSettingsLink.microphonePrivacyURL])
    }

    // MARK: - Helpers

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
