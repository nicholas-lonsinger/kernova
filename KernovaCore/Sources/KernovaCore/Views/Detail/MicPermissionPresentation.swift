import AVFoundation
import Foundation

/// What the Audio section should show beneath the Audio Input toggle, derived
/// purely from the system permission status and whether audio input is enabled.
package enum MicWarningState: Equatable {
    /// No supplementary UI: audio input disabled, permission granted, or not yet
    /// requested — macOS asks on first use.
    case none
    /// Audio input enabled but permission denied/restricted; shown as a warning
    /// with a link to System Settings.
    case denied
}

/// Maps the microphone authorization status to the supplementary UI to display.
func micPermissionPresentation(_ status: AVAuthorizationStatus, audioInputEnabled: Bool) -> MicWarningState {
    guard audioInputEnabled else { return .none }
    switch status {
    case .denied, .restricted:
        return .denied
    case .notDetermined, .authorized:
        return .none
    @unknown default:
        return .none
    }
}
