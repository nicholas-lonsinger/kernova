import AppKit
import KernovaCore

extension ReservedShortcut {
    /// The modifiers every reserved shortcut is held with.
    static let modifierMask: NSEvent.ModifierFlags = [.control, .shift, .command]

    /// The action of the menu item the shortcut belongs to.
    @MainActor var action: Selector {
        switch self {
        case .copyGuestClipboardToMac: #selector(AppDelegate.copyGuestClipboardToMac(_:))
        case .copyMacClipboardToGuest: #selector(AppDelegate.copyMacClipboardToGuest(_:))
        }
    }

    /// The shortcut as a menu shows it, such as "⌃⇧⌘C".
    var displayString: String {
        "⌃⇧⌘" + keyEquivalent.uppercased()
    }

    /// The reserved shortcut `event` presses, or `nil` when it presses none.
    ///
    /// Reads the key's characters with every modifier but Shift ignored, in
    /// either case, and requires exactly the shortcut's modifiers (Caps Lock
    /// and the keypad and function flags aside).
    init?(pressedBy event: NSEvent) {
        let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard held == Self.modifierMask, let key = event.charactersIgnoringModifiers?.lowercased(),
            let shortcut = Self.allCases.first(where: { $0.keyEquivalent == key })
        else { return nil }
        self = shortcut
    }

    /// Whether `item` is this shortcut's menu item and shows it.
    @MainActor func isShown(on item: NSMenuItem) -> Bool {
        item.action == action && item.keyEquivalent == keyEquivalent
            && item.keyEquivalentModifierMask == Self.modifierMask
    }

    /// Shows on every reserved shortcut's item in `menu` its shortcut, except
    /// on the items of the shortcuts in `disabled`, which show none.
    @MainActor static func apply(in menu: NSMenu, disabled: Set<ReservedShortcut>) {
        for item in menu.items {
            guard let shortcut = allCases.first(where: { $0.action == item.action }) else { continue }
            let isOn = !disabled.contains(shortcut)
            item.keyEquivalent = isOn ? shortcut.keyEquivalent : ""
            item.keyEquivalentModifierMask = isOn ? modifierMask : []
        }
    }
}
