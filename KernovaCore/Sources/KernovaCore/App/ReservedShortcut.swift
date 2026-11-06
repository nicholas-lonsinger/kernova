/// A key combination Kernova reserves for one of its commands: while it is on,
/// it acts in every Kernova window, a VM's screen included, and the guest never
/// receives it; while it is off, the command has no shortcut and the guest
/// receives the combination.
///
/// Every case is held with ⌃⇧⌘ (`ReservedShortcut.modifierMask` in KernovaUI).
/// The raw value is what `AppPreferences` stores.
package enum ReservedShortcut: String, CaseIterable, Sendable {
    case copyGuestClipboardToMac
    case copyMacClipboardToGuest

    /// The title of the command the shortcut runs, as its menu item shows it.
    package var commandTitle: String {
        switch self {
        case .copyGuestClipboardToMac: "Copy Guest Clipboard to Mac"
        case .copyMacClipboardToGuest: "Copy Mac Clipboard to Guest"
        }
    }

    /// The menu item's key equivalent while the shortcut is on.
    package var keyEquivalent: String {
        switch self {
        case .copyGuestClipboardToMac: "c"
        case .copyMacClipboardToGuest: "v"
        }
    }
}
