import Foundation

/// One item in the app menu's quit section, as decided by
/// ``items(downgradesQuitToGUIClose:)``.
struct AppMenuQuitItem: Equatable {
    /// What invoking the item does.
    enum Action: Equatable {
        /// Routes through `NSApplication.terminate(_:)` and thus the
        /// `applicationShouldTerminate` gate.
        case terminateThroughGate
        /// Requests an unconditional full quit, bypassing the
        /// keep-in-menu-bar downgrade.
        case quitCompletely
    }

    let title: String
    /// The key-equivalent character (always `"q"`; ⌘ is always part of the shortcut).
    let keyEquivalent: String
    /// Whether Option joins Command: `false` = ⌘Q, `true` = ⌥⌘Q.
    let usesOptionModifier: Bool
    let action: Action

    /// Decides the app menu's quit-section items, so every state presents an
    /// honest command.
    ///
    /// A process whose ⌘Q would be downgraded to a GUI close gets the honest
    /// split — "Close All Windows" (⌘Q) plus the true "Quit Kernova" (⌥⌘Q);
    /// anywhere ⌘Q really quits, it is the single item that says so.
    static func items(downgradesQuitToGUIClose: Bool) -> [AppMenuQuitItem] {
        if downgradesQuitToGUIClose {
            return [
                AppMenuQuitItem(
                    title: "Close All Windows", keyEquivalent: "q",
                    usesOptionModifier: false, action: .terminateThroughGate),
                AppMenuQuitItem(
                    title: "Quit Kernova", keyEquivalent: "q",
                    usesOptionModifier: true, action: .quitCompletely),
            ]
        }
        return [
            AppMenuQuitItem(
                title: "Quit Kernova", keyEquivalent: "q",
                usesOptionModifier: false, action: .terminateThroughGate)
        ]
    }
}
