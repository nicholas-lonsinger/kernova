import AppKit

/// System Settings deep links for enabling a clipboard File Provider extension.
///
/// macOS gates third-party File Provider extensions behind a per-extension toggle
/// in System Settings → General → Login Items & Extensions → File Providers, off
/// by default.
public enum ClipboardFileProviderSettings {
    /// `x-apple.systempreferences:` URLs that open the File-Providers enablement
    /// UI, most specific first.
    ///
    /// These deep links are private and unguaranteed across macOS releases, so a
    /// caller tries them in order and opens the first that works; the exact
    /// anchor is not load-bearing.
    public static let enablementDeepLinks: [String] = [
        "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fileprovider-nonui",
        "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems",
    ]

    /// Opens System Settings to the File-Providers enablement pane, trying
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
