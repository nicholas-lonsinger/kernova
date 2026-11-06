import AppKit

/// Kernova's `NSApplication`: takes the reserved shortcuts the menu bar shows
/// before any window sees them (``ReservedShortcutCatcher``).
///
/// The composition root makes it the shared application by calling
/// `KernovaApplication.shared` before anything else touches `NSApp`.
@objc(KernovaApplication)
public final class KernovaApplication: NSApplication {
    private let reservedShortcuts = ReservedShortcutCatcher()

    override public func sendEvent(_ event: NSEvent) {
        if reservedShortcuts.catches(event, in: mainMenu) { return }
        super.sendEvent(event)
    }
}
