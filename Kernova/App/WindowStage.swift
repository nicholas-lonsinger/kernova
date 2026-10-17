import AppKit

/// Where the app's window controllers make their windows: the names AppKit
/// saves their state under, and the window objects themselves.
///
/// Every window controller builds its window through its stage, so a stage that
/// makes its windows somewhere else holds every window the app makes there.
struct WindowStage: Sendable {
    /// The names AppKit saves these windows' state under.
    let autosave: WindowAutosave

    /// Makes a buffered window with `contentRect` and `styleMask`, its window
    /// device created at once.
    let makeWindow: @MainActor @Sendable (_ contentRect: NSRect, _ styleMask: NSWindow.StyleMask) -> NSWindow

    /// Makes `NSWindow(contentViewController:)`'s window for `contentViewController`.
    let makeContentWindow: @MainActor @Sendable (_ contentViewController: NSViewController) -> NSWindow

    /// The app's own windows.
    static let app = WindowStage(
        autosave: .app,
        makeWindow: { contentRect, styleMask in
            NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        },
        makeContentWindow: { NSWindow(contentViewController: $0) })

    /// Makes a window hosting `contentViewController` whose content size is
    /// exactly `contentSize`.
    ///
    /// Assigning `contentViewController` resizes the window to the content view's
    /// Auto Layout fitting size, which for a flexible content view is far smaller
    /// than the intended initial size — and `minSize`, set afterwards, then clamps
    /// the window up to *that*. Re-establishing the size after the assignment is
    /// the only ordering that sticks.
    @MainActor
    func makeWindow(
        stableContentSize contentSize: NSSize,
        styleMask: NSWindow.StyleMask,
        contentViewController: NSViewController
    ) -> NSWindow {
        let window = makeWindow(NSRect(origin: .zero, size: contentSize), styleMask)
        window.contentViewController = contentViewController
        window.setContentSize(contentSize)
        return window
    }
}
