import AVFoundation
import Foundation

/// What the Audio section should show beneath the Audio Input toggle, derived
/// purely from the system permission status and whether audio input is enabled.
enum MicWarningState: Equatable {
    /// No supplementary UI (audio input disabled, or already authorized).
    case none
    /// Audio input enabled but permission not yet requested; macOS will prompt on
    /// first use. Shown as a neutral hint.
    case willPrompt
    /// Audio input enabled but permission denied/restricted; shown as a warning
    /// with a link to the permission instructions.
    case denied
}

/// Maps the microphone authorization status to the supplementary UI to display.
func micPermissionPresentation(_ status: AVAuthorizationStatus, audioInputEnabled: Bool) -> MicWarningState {
    guard audioInputEnabled else { return .none }
    switch status {
    case .notDetermined:
        return .willPrompt
    case .denied, .restricted:
        return .denied
    case .authorized:
        return .none
    @unknown default:
        return .none
    }
}

/// Whether the Guest Agent settings section applies to a guest OS.
///
/// The guest agent ships only for macOS guests, so the section is hidden for
/// Linux. On macOS it also gates whether clipboard sharing nests inside the
/// agent group; on Linux clipboard is SPICE-based and stands alone.
func isGuestAgentSectionVisible(guestOS: VMGuestOS) -> Bool {
    guestOS == .macOS
}
