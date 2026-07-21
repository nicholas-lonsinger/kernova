import AppKit
import Testing

@testable import Kernova

@Suite("NSWindow.withStableContentSize Tests")
@MainActor
struct NSWindowExtensionsTests {
    /// A content view controller whose Auto Layout fitting size is far smaller
    /// than any realistic window — the shape that makes a plain
    /// `contentViewController` assignment shrink the window (#582).
    private func makeFlexibleContentViewController() -> NSViewController {
        let controller = NSViewController()
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 10),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 10),
        ])
        controller.view = content
        return controller
    }

    @Test("Content size survives the contentViewController assignment")
    func contentSizeSurvivesAssignment() {
        let size = NSSize(width: 1200, height: 900)
        let window = NSWindow.withStableContentSize(
            size,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            contentViewController: makeFlexibleContentViewController()
        )

        let contentSize = window.contentRect(forFrameRect: window.frame).size
        #expect(contentSize.width == size.width)
        #expect(contentSize.height == size.height)
    }

    /// The regression guard: a later `minSize` must clamp against the requested
    /// size, never against the content view's (much smaller) fitting size.
    @Test("A later minSize does not shrink the window to the fitting size")
    func minSizeDoesNotClampToFittingSize() {
        let size = NSSize(width: 1200, height: 900)
        let window = NSWindow.withStableContentSize(
            size,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            contentViewController: makeFlexibleContentViewController()
        )
        window.minSize = NSSize(width: 800, height: 500)

        let contentSize = window.contentRect(forFrameRect: window.frame).size
        #expect(contentSize.width == size.width)
        #expect(contentSize.height == size.height)
    }

    @Test("The content view controller is installed on the window")
    func installsContentViewController() {
        let controller = makeFlexibleContentViewController()
        let window = NSWindow.withStableContentSize(
            NSSize(width: 480, height: 320),
            styleMask: [.titled, .closable],
            contentViewController: controller
        )

        #expect(window.contentViewController === controller)
        #expect(window.styleMask.contains(.titled))
    }
}
