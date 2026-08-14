import AppKit
import os

/// Opens the System Settings panes Kernova sends users to.
///
/// The `open` closure is the seam tests substitute for `NSWorkspace`.
@MainActor
struct SystemSettingsLink {
    /// Privacy & Security → Microphone.
    ///
    /// Observed 2026-08-14 on macOS 26: this URL lands System Settings on the
    /// Microphone sub-pane, not just the Privacy & Security root.
    static let microphonePrivacyURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    /// Privacy & Security with no sub-pane anchor.
    static let privacySecurityURL = "x-apple.systempreferences:com.apple.preference.security"

    private static let logger = Logger(subsystem: "app.kernova", category: "SystemSettingsLink")

    private let open: @MainActor (URL) -> Bool

    init(open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.open = open
    }

    /// Opens System Settings on the Microphone privacy pane, falling back to the
    /// unanchored Privacy & Security pane when the anchored URL does not open.
    @discardableResult
    func openMicrophonePrivacy() -> Bool {
        for string in [Self.microphonePrivacyURL, Self.privacySecurityURL] {
            guard let url = URL(string: string) else {
                Self.logger.fault("Malformed System Settings URL '\(string, privacy: .public)'")
                assertionFailure("Malformed System Settings URL: \(string)")
                continue
            }
            if open(url) { return true }
        }
        Self.logger.warning("System Settings did not open for microphone permission")
        return false
    }
}
