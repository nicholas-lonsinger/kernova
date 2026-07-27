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

/// Absolute path → security bookmark of every user-supplied attachment
/// (external storage disks + removable media) for a configuration.
///
/// Internal disks are excluded — they live inside the VM bundle and can't be
/// moved out from under the app. The bookmark is what lets the sandboxed monitor
/// probe existence of out-of-container paths; should the same path appear on
/// both lists, a non-nil bookmark wins.
func externalAttachmentRefs(for configuration: VMConfiguration) -> [String: Data?] {
    var refs: [String: Data?] = [:]
    func add(_ path: String, _ bookmark: Data?) {
        if (refs[path] ?? nil) != nil { return }
        refs.updateValue(bookmark, forKey: path)
    }
    if let disks = configuration.storageDisks {
        for disk in disks where !disk.isInternal {
            add(disk.path, disk.bookmark)
        }
    }
    if let media = configuration.removableMedia {
        for item in media {
            add(item.path, item.bookmark)
        }
    }
    return refs
}

/// Whether the Guest Agent settings section applies to a guest OS.
///
/// The guest agent ships only for macOS guests, so the section is hidden for
/// Linux. On macOS it also gates whether clipboard sharing nests inside the
/// agent group; on Linux clipboard is SPICE-based and stands alone.
func isGuestAgentSectionVisible(guestOS: VMGuestOS) -> Bool {
    guestOS == .macOS
}
