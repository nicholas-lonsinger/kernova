import AppKit
import KernovaCore

/// The Edit menu's clipboard commands for the working window's VM: one item per direction, and the passthrough
/// switch.
///
/// Each direction's shortcut is a ``ReservedShortcut``, which `MainMenuController` shows on the item while the user
/// has it on.
enum ClipboardCommandMenu {
    static let passthroughTitle = "Automatic Clipboard Passthrough"

    /// The three items, in menu order, before any shortcut is applied.
    @MainActor static func items() -> [NSMenuItem] {
        let directions = [ReservedShortcut.copyGuestClipboardToMac, .copyMacClipboardToGuest].map {
            NSMenuItem(title: $0.commandTitle, action: $0.action, keyEquivalent: "")
        }
        let passthrough = NSMenuItem(
            title: passthroughTitle, action: #selector(AppDelegate.toggleClipboardPassthrough(_:)), keyEquivalent: "")
        return directions + [passthrough]
    }
}
