import AppKit

/// The Edit menu's clipboard commands for the working window's VM: one item per direction, and the passthrough
/// switch.
///
/// ⌃⇧⌘C and ⌃⇧⌘V reach the menu, as every Kernova command's shortcut does, only while the VM's display does
/// not capture system keys; a capturing display sends them to the guest.
enum ClipboardCommandMenu {
    static let copyToMacTitle = "Copy Guest Clipboard to Mac"
    static let copyToGuestTitle = "Copy Mac Clipboard to Guest"
    static let passthroughTitle = "Automatic Clipboard Passthrough"

    /// The three items, in menu order.
    @MainActor static func items() -> [NSMenuItem] {
        let toMac = NSMenuItem(
            title: copyToMacTitle, action: #selector(AppDelegate.copyGuestClipboardToMac(_:)), keyEquivalent: "c")
        toMac.keyEquivalentModifierMask = [.control, .shift, .command]
        let toGuest = NSMenuItem(
            title: copyToGuestTitle, action: #selector(AppDelegate.copyMacClipboardToGuest(_:)), keyEquivalent: "v")
        toGuest.keyEquivalentModifierMask = [.control, .shift, .command]
        let passthrough = NSMenuItem(
            title: passthroughTitle, action: #selector(AppDelegate.toggleClipboardPassthrough(_:)), keyEquivalent: "")
        return [toMac, toGuest, passthrough]
    }
}
