import AppKit

/// System Settings deep links for enabling a clipboard File Provider extension.
///
/// macOS gates third-party File Provider extensions behind a per-extension toggle
/// in System Settings → General → Login Items & Extensions → File Providers, off
/// by default. Both the guest agent (host→guest paste) and the host app
/// (guest→host "Copy to Mac") surface a "needs enabling" affordance that opens
/// this pane, so the candidate URLs live here as one source of truth.
public enum ClipboardFileProviderSettings {
    /// `x-apple.systempreferences:` URLs that open the File-Providers enablement
    /// UI, most specific first.
    ///
    /// These deep links are private and unguaranteed across macOS releases, so a
    /// caller should try them in order and open the first that works; either way
    /// the user lands in System Settings and can enable the extension. The exact
    /// anchor is intentionally non-load-bearing.
    public static let enablementDeepLinks: [String] = [
        "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fileprovider-nonui",
        "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems",
    ]

    /// Opens System Settings to the File-Providers enablement pane, trying
    /// `enablementDeepLinks` in order and stopping at the first that opens.
    ///
    /// Shared by the three "Enable in System Settings…" affordances (host
    /// clipboard window banner, host status item, guest status item) so the
    /// try-in-order loop lives in one place; each caller logs a failure with
    /// its own file-appropriate logger.
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
