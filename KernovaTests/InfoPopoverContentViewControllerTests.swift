import Testing
import AppKit
import KernovaTestSupport
@testable import Kernova

@Suite("InfoPopoverContentViewController Tests", .caseScoped)
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

    @Test("A body's code span renders monospaced without its backticks")
    func bodyCodeSpanRendersMonospaced() throws {
        let vc = InfoPopoverContentViewController(paragraphs: [
            .body("The interface usually appears as `enp0s1`. Check `os.Logger`.")
        ])
        vc.loadViewIfNeeded()
        let label = try #require(
            (vc.view.subviews.first as? NSStackView)?.arrangedSubviews.first as? NSTextField)
        #expect(label.stringValue == "The interface usually appears as enp0s1. Check os.Logger.")

        let rendered = label.attributedStringValue
        func font(at substring: String) -> NSFont? {
            let range = (rendered.string as NSString).range(of: substring)
            return rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }
        #expect(font(at: "enp0s1")?.isFixedPitch == true)
        #expect(font(at: "os.Logger")?.isFixedPitch == true)
        #expect(font(at: "The interface")?.isFixedPitch == false)
    }

    @Test("An unpaired backtick in a body stays as written")
    func unpairedBacktickStaysLiteral() {
        let rendered = InfoPopoverContentViewController.renderedBody("Use `a` then ` alone")
        #expect(rendered.string == "Use a then ` alone")
    }

    @Test("empty paragraph list still loads")
    func emptyParagraphList() {
        let vc = InfoPopoverContentViewController(paragraphs: [])
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.view.fittingSize.width == CalloutStyle.width)
    }

    @Test("body paragraphs are non-selectable, code paragraphs are selectable")
    func paragraphSelectability() {
        let vc = InfoPopoverContentViewController(paragraphs: [
            .body("Plain prose."),
            .code("mount -t virtiofs share0 /mnt/myshare"),
        ])
        vc.loadViewIfNeeded()

        guard let stack = vc.view.subviews.first as? NSStackView else {
            Issue.record("Expected NSStackView as the first container subview")
            return
        }
        let labels = stack.arrangedSubviews.compactMap { $0 as? NSTextField }
        let body = labels.first { $0.stringValue == "Plain prose." }
        let code = labels.first { $0.stringValue == "mount -t virtiofs share0 /mnt/myshare" }
        #expect(body?.isSelectable == false)
        #expect(code?.isSelectable == true)
    }
}
