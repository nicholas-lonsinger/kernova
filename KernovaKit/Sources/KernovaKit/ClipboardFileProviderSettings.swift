import AppKit

/// Settings-app deep links for enabling a clipboard File Provider extension.
///
/// macOS gates third-party File Provider extensions behind a per-extension
/// toggle, off by default: System Settings → General → Login Items &
/// Extensions → File Providers on 13+, System Preferences → Extensions → Added
/// Extensions below.
public enum ClipboardFileProviderSettings {
    /// URLs that open the File-Providers enablement UI on the running OS, most
    /// specific first.
    public static var enablementDeepLinks: [String] {
        if #available(macOS 13.0, *) { return enablementDeepLinks(systemSettings: true) }
        return enablementDeepLinks(systemSettings: false)
    }

    /// The candidate list for an OS that has System Settings (macOS 13+) or one
    /// that still has System Preferences — taken as a parameter so both lists
    /// are reachable from either OS.
    ///
    /// A caller tries them in order and opens the first that works; the exact
    /// anchor is not load-bearing. Below 13 the leading entry is the Extensions
    /// pane bundle's own file URL rather than an `x-apple.systempreferences:`
    /// one, because System Preferences does not route the
    /// `com.apple.preferences.extensions` pane id — it opens at the main grid,
    /// with or without a trailing anchor, while `NSWorkspace` still reports
    /// success (`docs/research/2026-08-03-macos12-extensions-pane-deep-link.md`).
    /// Opening the bundle lands on Extensions with the agent's checkbox in view.
    public static func enablementDeepLinks(systemSettings: Bool) -> [String] {
        guard systemSettings else {
            return [
                "file:///System/Library/PreferencePanes/Extensions.prefPane",
                "x-apple.systempreferences:com.apple.preferences.extensions",
            ]
        }
        return [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fileprovider-nonui",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems",
        ]
    }

    /// Opens the settings app to the File-Providers enablement pane, trying
    /// `enablementDeepLinks` in order and stopping at the first that opens.
    ///
    /// - Returns: `true` if a URL was opened, `false` if every candidate failed.
    @discardableResult
    public static func openEnablementSettings() -> Bool {
        for string in enablementDeepLinks {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return true }
        }
        return false
    }
}
