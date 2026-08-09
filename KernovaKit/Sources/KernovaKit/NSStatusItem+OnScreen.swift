import AppKit

extension NSStatusItem {
    /// Whether the item's button is on a screen right now.
    ///
    /// The button's window outlives macOS dropping the item from a crowded menu
    /// bar and a full-screen window covering the menu bar, so its existence
    /// proves nothing: only a visible window landing on a display does. Paired
    /// with ``isVisible``, which reports the app's own preference rather than
    /// anything about the screen.
    public var isButtonOnScreen: Bool {
        guard let window = button?.window, window.isVisible else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }
}
