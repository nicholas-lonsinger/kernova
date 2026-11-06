import AppKit
import KernovaCore

/// Takes the key presses of the reserved shortcuts a menu shows before AppKit
/// dispatches them, so a VM's screen never sees them, and runs each shortcut's
/// menu item.
///
/// A shortcut is caught exactly while its menu item shows it, so no shortcut is
/// shown that a VM's screen takes instead, and none is caught that the menu does
/// not show.
///
/// `KernovaApplication.sendEvent(_:)` asks it about every event before calling
/// `NSApplication.sendEvent(_:)`, the method that dispatches events to
/// responders. Local event monitors see only "events that are dispatched through
/// the application's `sendEvent:` method" (`NSEvent.addLocalMonitorForEvents`),
/// so a press taken here reaches neither a responder nor a monitor, whichever of
/// them a VM's screen takes its keys through.
@MainActor
final class ReservedShortcutCatcher {
    /// The keys whose press this catcher took and whose release it still owes
    /// the same fate, so the guest never sees half of a press.
    private var heldKeyCodes: Set<UInt16> = []

    /// Whether `event` belongs to a reserved shortcut `menu` shows, in which
    /// case its item has run if enabled and the event must not be dispatched.
    ///
    /// A press is taken whether or not the item is enabled: the guest never
    /// receives a shortcut that is on.
    func catches(_ event: NSEvent, in menu: NSMenu?) -> Bool {
        switch event.type {
        case .keyDown:
            guard let shortcut = ReservedShortcut(pressedBy: event), let menu,
                let item = Self.item(showing: shortcut, in: menu)
            else { return false }
            heldKeyCodes.insert(event.keyCode)
            perform(item)
            return true
        case .keyUp:
            return heldKeyCodes.remove(event.keyCode) != nil
        default:
            return false
        }
    }

    /// Validates `item` the way an opening menu would, then sends its action
    /// if that leaves it enabled.
    private func perform(_ item: NSMenuItem) {
        guard let owner = item.menu else { return }
        owner.update()
        guard item.isEnabled else { return }
        owner.performActionForItem(at: owner.index(of: item))
    }

    /// The item in `menu` or its submenus that shows `shortcut`.
    private static func item(showing shortcut: ReservedShortcut, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if shortcut.isShown(on: item) { return item }
            if let submenu = item.submenu, let found = Self.item(showing: shortcut, in: submenu) {
                return found
            }
        }
        return nil
    }
}
