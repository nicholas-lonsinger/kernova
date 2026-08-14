import AppKit
import Testing

@testable import Kernova

/// Records the URLs handed to `SystemSettingsLink`, answering each attempt with
/// the next queued result.
@MainActor
final class URLOpenRecorder {
    private(set) var opened: [String] = []
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func open(_ url: URL) -> Bool {
        opened.append(url.absoluteString)
        return results.isEmpty ? false : results.removeFirst()
    }
}

@Suite("SystemSettingsLink Tests")
@MainActor
struct SystemSettingsLinkTests {
    private let anchored = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    private let unanchored = "x-apple.systempreferences:com.apple.preference.security"

    @Test("The anchored Microphone URL is tried first, with no fallback when it opens")
    func anchoredURLOpensAlone() {
        let recorder = URLOpenRecorder(results: [true])
        let link = SystemSettingsLink(open: recorder.open)

        #expect(link.openMicrophonePrivacy())
        #expect(recorder.opened == [anchored])
    }

    @Test("A failed anchored open falls back to the Privacy & Security pane")
    func fallsBackToPrivacyPane() {
        let recorder = URLOpenRecorder(results: [false, true])
        let link = SystemSettingsLink(open: recorder.open)

        #expect(link.openMicrophonePrivacy())
        #expect(recorder.opened == [anchored, unanchored])
    }

    @Test("Both URLs failing reports failure after trying each once")
    func bothURLsFailing() {
        let recorder = URLOpenRecorder(results: [false, false])
        let link = SystemSettingsLink(open: recorder.open)

        #expect(!link.openMicrophonePrivacy())
        #expect(recorder.opened == [anchored, unanchored])
    }

    @Test("The published URL constants match the panes the app links to")
    func urlConstantsAreStable() {
        #expect(SystemSettingsLink.microphonePrivacyURL == anchored)
        #expect(SystemSettingsLink.privacySecurityURL == unanchored)
    }
}
