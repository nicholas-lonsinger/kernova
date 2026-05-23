import Testing
import AppKit
@testable import Kernova

@Suite("MissingAttachmentPopoverContentViewController Tests")
@MainActor
struct MissingAttachmentPopoverContentViewControllerTests {
    @Test("loadView fits the CalloutStyle width")
    func fittingWidthMatchesStyle() {
        let vc = MissingAttachmentPopoverContentViewController(path: "/tmp/missing.iso")
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.view.fittingSize.width == CalloutStyle.width)
    }

    @Test("fitting height accommodates content")
    func fittingHeightIsPositive() {
        let vc = MissingAttachmentPopoverContentViewController(path: "/tmp/missing.iso")
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.view.fittingSize.height > 0)
    }

    @Test("path label is selectable and uses character wrapping")
    func pathLabelConfiguration() {
        let path = "/Users/test/Downloads/very/long/path/to/missing-file.ipsw"
        let vc = MissingAttachmentPopoverContentViewController(path: path)
        vc.loadViewIfNeeded()

        guard let stack = vc.view.subviews.first as? NSStackView else {
            Issue.record("Expected NSStackView as the first container subview")
            return
        }

        // Find the wrapping path NSTextField by string value match.
        let pathLabel = stack.arrangedSubviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == path }
        guard let label = pathLabel else {
            Issue.record("Expected an NSTextField rendering the path")
            return
        }
        #expect(label.isSelectable)
        #expect(label.lineBreakMode == .byCharWrapping)
        #expect(label.maximumNumberOfLines == 0)
    }

    @Test("header row contains the warning icon and headline")
    func headerHasIconAndTitle() {
        let vc = MissingAttachmentPopoverContentViewController(path: "/tmp/missing.iso")
        vc.loadViewIfNeeded()

        guard let stack = vc.view.subviews.first as? NSStackView,
            let header = stack.arrangedSubviews.first as? NSStackView
        else {
            Issue.record("Expected header NSStackView as the first arranged subview")
            return
        }
        let hasIcon = header.arrangedSubviews.contains { $0 is NSImageView }
        let hasHeadline = header.arrangedSubviews.contains {
            ($0 as? NSTextField)?.stringValue == "File Missing"
        }
        #expect(hasIcon)
        #expect(hasHeadline)
    }
}
