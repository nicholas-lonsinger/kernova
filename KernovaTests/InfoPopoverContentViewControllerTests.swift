import Testing
import AppKit
@testable import Kernova

@Suite("InfoPopoverContentViewController Tests")
@MainActor
struct InfoPopoverContentViewControllerTests {
    @Test("loadView fits the CalloutStyle width")
    func fittingWidthMatchesStyle() {
        let vc = InfoPopoverContentViewController(paragraphs: [.body("Hello")])
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.view.fittingSize.width == CalloutStyle.width)
    }

    @Test("each body paragraph renders as a wrapping NSTextField")
    func bodyParagraphsRender() {
        let texts = ["First paragraph.", "Second paragraph.", "Third paragraph."]
        let vc = InfoPopoverContentViewController(paragraphs: texts.map { .body($0) })
        vc.loadViewIfNeeded()

        guard let stack = vc.view.subviews.first as? NSStackView else {
            Issue.record("Expected NSStackView as the first container subview")
            return
        }
        #expect(stack.arrangedSubviews.count == texts.count)
        let rendered = stack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(rendered == texts)
    }

    @Test("code paragraph renders monospaced and selectable")
    func codeParagraphRenders() {
        let snippet = "mount -t virtiofs share0 /mnt/myshare"
        let vc = InfoPopoverContentViewController(paragraphs: [
            .body("Mount with:"),
            .code(snippet),
        ])
        vc.loadViewIfNeeded()

        guard let stack = vc.view.subviews.first as? NSStackView else {
            Issue.record("Expected NSStackView as the first container subview")
            return
        }
        let codeLabel = stack.arrangedSubviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == snippet }
        guard let label = codeLabel else {
            Issue.record("Expected the code paragraph to render as an NSTextField")
            return
        }
        #expect(label.isSelectable)
        // Verify monospaced — derived from `monospacedSystemFont`, the
        // resulting NSFont's `isFixedPitch` flag is set.
        #expect(label.font?.isFixedPitch == true)
    }

    @Test("empty paragraph list still loads")
    func emptyParagraphList() {
        let vc = InfoPopoverContentViewController(paragraphs: [])
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.view.fittingSize.width == CalloutStyle.width)
    }
}
