import Testing
import AppKit
@testable import Kernova

@Suite("CalloutContentViewController Tests")
@MainActor
struct CalloutContentViewControllerTests {
    @Test("default fitting width is 340pt")
    func defaultWidth() {
        let vc = CalloutContentViewController()
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.view.fittingSize.width == CalloutContentViewController.defaultWidth)
    }

    @Test("bodyWidth equals contentWidth minus 2× padding")
    func bodyWidthIsContentMinusPadding() {
        let vc = CalloutContentViewController()
        let expected =
            CalloutContentViewController.defaultWidth
            - CalloutContentViewController.padding * 2
        #expect(vc.bodyWidth == expected)
    }

    @Test("custom fitting width is honored")
    func customWidth() {
        let vc = CalloutContentViewController(width: 400)
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.view.fittingSize.width == 400)
        #expect(vc.bodyWidth == 400 - CalloutContentViewController.padding * 2)
    }

    @Test("addHeadline appends a label")
    func addHeadlineAppends() {
        let vc = CalloutContentViewController()
        vc.loadViewIfNeeded()
        let initialSubviewCount = vc.view.subviews.first?.subviews.count ?? 0
        vc.addHeadline("Hello")
        let finalSubviewCount = vc.view.subviews.first?.subviews.count ?? 0
        #expect(finalSubviewCount == initialSubviewCount + 1)
    }

    @Test("addBody appends a wrapping label")
    func addBodyAppends() {
        let vc = CalloutContentViewController()
        vc.loadViewIfNeeded()
        vc.addBody("Some text")
        // The arranged stack is the first subview; its arranged subviews
        // contain the labels we add.
        guard let stack = vc.view.subviews.first as? NSStackView else {
            Issue.record("Expected NSStackView as the first subview")
            return
        }
        #expect(stack.arrangedSubviews.count == 1)
        let label = stack.arrangedSubviews.first as? NSTextField
        #expect(label?.stringValue == "Some text")
    }

    @Test("addArrangedContent appends arbitrary views")
    func addArrangedContent() {
        let vc = CalloutContentViewController()
        vc.loadViewIfNeeded()
        let custom = NSView()
        vc.addArrangedContent(custom)
        let stack = vc.view.subviews.first as? NSStackView
        #expect(stack?.arrangedSubviews.contains(custom) == true)
    }
}
