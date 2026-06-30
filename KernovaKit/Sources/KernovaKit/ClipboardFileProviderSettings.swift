import Foundation

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
}
