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

    private static let logger = Logger(subsystem: "app.kernova", category: "SystemSettingsLink")

    private let open: @MainActor (URL) -> Bool

    init(open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.open = open
    }

    /// Opens System Settings on the Microphone privacy pane.
    ///
    /// Returns whether System Settings launched — not whether it reached the
    /// Microphone sub-pane. The `?Privacy_Microphone` anchor is opaque to
    /// Launch Services, which resolves only the scheme, so an anchor macOS
    /// stops honoring still opens System Settings and still reports success.
    /// That is the graceful degradation for a dropped anchor: the user lands in
    /// System Settings, and the popover's written steps carry them the rest of
    /// the way. A second, unanchored URL would share this one's scheme and pane
    /// id, so it could never succeed where this one failed.
    @discardableResult
    func openMicrophonePrivacy() -> Bool {
        guard let url = URL(string: Self.microphonePrivacyURL) else {
            Self.logger.fault(
                "Malformed System Settings URL '\(Self.microphonePrivacyURL, privacy: .public)'")
            assertionFailure("Malformed System Settings URL: \(Self.microphonePrivacyURL)")
            return false
        }
        guard open(url) else {
            Self.logger.warning("System Settings did not open for microphone permission")
            return false
        }
        return true
    }
}
