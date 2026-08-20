import AppKit
import Testing

@testable import Kernova

@Suite("SystemSettingsLink Tests", .admissionGated)
@MainActor
struct SystemSettingsLinkTests {
    private let anchored = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    @Test("Opening the microphone pane hands the anchored URL to the workspace")
    func opensAnchoredMicrophoneURL() {
        let recorder = URLOpenRecorder(results: [true])
        let link = SystemSettingsLink(open: recorder.open)

        #expect(link.openMicrophonePrivacy())
        #expect(recorder.opened == [anchored])
    }

    @Test("A workspace that cannot open the URL reports failure without retrying")
    func failedOpenReportsFailure() {
        let recorder = URLOpenRecorder(results: [false])
        let link = SystemSettingsLink(open: recorder.open)

        #expect(!link.openMicrophonePrivacy())
        #expect(recorder.opened == [anchored])
    }

    @Test("The published URL constant matches the pane the app links to")
    func urlConstantIsStable() {
        #expect(SystemSettingsLink.microphonePrivacyURL == anchored)
    }
}
