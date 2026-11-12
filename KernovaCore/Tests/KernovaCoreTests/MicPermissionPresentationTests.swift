import AVFoundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("MicPermissionPresentation Tests", .caseScoped)
struct MicPermissionPresentationTests {
    // MARK: - Audio input enabled → status-driven

    @Test("Enabled audio input maps each status to the expected warning state")
    func enabledAudioInputMapping() {
        #expect(micPermissionPresentation(.notDetermined, audioInputEnabled: true) == .none)
        #expect(micPermissionPresentation(.denied, audioInputEnabled: true) == .denied)
        #expect(micPermissionPresentation(.restricted, audioInputEnabled: true) == .denied)
        #expect(micPermissionPresentation(.authorized, audioInputEnabled: true) == .none)
    }
}
