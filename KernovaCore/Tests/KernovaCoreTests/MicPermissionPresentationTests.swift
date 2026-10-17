import AVFoundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("MicPermissionPresentation Tests", .caseScoped)
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
        #expect(micPermissionPresentation(.notDetermined, audioInputEnabled: true) == .none)
        #expect(micPermissionPresentation(.denied, audioInputEnabled: true) == .denied)
        #expect(micPermissionPresentation(.restricted, audioInputEnabled: true) == .denied)
        #expect(micPermissionPresentation(.authorized, audioInputEnabled: true) == .none)
    }
}
