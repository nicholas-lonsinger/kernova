import Cocoa

extension NSWindow {
    /// Creates a window hosting `contentViewController` whose content size is
    /// exactly `contentSize`.
    ///
    /// RATIONALE: assigning `contentViewController` resizes the window to the
    /// content view's Auto Layout fitting size, which for a flexible content view
    /// is far smaller than the intended initial size — and `minSize`, set
    /// afterwards, then clamps the window up to *that*. Re-establishing the size
    /// after the assignment is the only ordering that sticks. verified 2026-07-27
    static func withStableContentSize(
        _ contentSize: NSSize,
        styleMask: NSWindow.StyleMask,
        contentViewController: NSViewController
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        window.setContentSize(contentSize)
        return window
    }
}
