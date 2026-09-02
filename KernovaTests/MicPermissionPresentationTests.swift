import AVFoundation
import Testing
@testable import Kernova

@Suite("MicPermissionPresentation Tests", .admissionGated)
struct MicPermissionPresentationTests {
    // MARK: - Audio input disabled → never any supplementary UI

    @Test("Disabled audio input shows nothing regardless of permission status")
    func disabledAudioInputShowsNothing() {
        for status in [
            AVAuthorizationStatus.notDetermined, .denied, .restricted, .authorized,
        ] {
            #expect(micPermissionPresentation(status, audioInputEnabled: false) == .none)
        }
    }

    // MARK: - Audio input enabled → status-driven

    @Test("Enabled audio input maps each status to the expected warning state")
    func enabledAudioInputMapping() {
        #expect(micPermissionPresentation(.notDetermined, audioInputEnabled: true) == .willPrompt)
        #expect(micPermissionPresentation(.denied, audioInputEnabled: true) == .denied)
        #expect(micPermissionPresentation(.restricted, audioInputEnabled: true) == .denied)
        #expect(micPermissionPresentation(.authorized, audioInputEnabled: true) == .none)
    }

    // MARK: - Guest agent section visibility

    @Test("Guest Agent section is visible only for macOS guests")
    func guestAgentVisibility() {
        #expect(isGuestAgentSectionVisible(guestOS: .macOS) == true)
        #expect(isGuestAgentSectionVisible(guestOS: .linux) == false)
    }
}
