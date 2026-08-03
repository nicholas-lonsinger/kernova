import Foundation
import Testing

@testable import KernovaKit

@Suite("ClipboardFileProviderSettings")
struct ClipboardFileProviderSettingsTests {
    @Test("every candidate on both OS eras parses as a URL", arguments: [true, false])
    func everyCandidateParses(systemSettings: Bool) {
        let candidates = ClipboardFileProviderSettings.enablementDeepLinks(
            systemSettings: systemSettings)
        #expect(!candidates.isEmpty)
        for string in candidates {
            #expect(URL(string: string) != nil, "unparseable candidate: \(string)")
        }
    }

    /// The file URL has to lead: it is the only candidate that fails honestly.
    ///
    /// `NSWorkspace.open` reports success for an `x-apple.systempreferences:`
    /// URL whose pane id does not resolve, so an entry placed after one can
    /// never run — and on 12 the file URL is also the only one that arrives.
    @Test("the System Preferences list leads with the pane bundle's file URL")
    func preSystemSettingsListLeadsWithFileURL() throws {
        let candidates = ClipboardFileProviderSettings.enablementDeepLinks(systemSettings: false)
        let leading = try #require(candidates.first.flatMap { URL(string: $0) })
        #expect(leading.isFileURL)
        #expect(leading.pathExtension == "prefPane")
    }

    @Test("the System Settings list addresses the File Provider extension point")
    func systemSettingsListNamesTheExtensionPoint() {
        let candidates = ClipboardFileProviderSettings.enablementDeepLinks(systemSettings: true)
        #expect(candidates.first?.contains("com.apple.fileprovider-nonui") == true)
    }

    @Test("the running OS picks the era-appropriate list")
    func runningOSPicksItsOwnList() {
        let expected: [String]
        if #available(macOS 13.0, *) {
            expected = ClipboardFileProviderSettings.enablementDeepLinks(systemSettings: true)
        } else {
            expected = ClipboardFileProviderSettings.enablementDeepLinks(systemSettings: false)
        }
        #expect(ClipboardFileProviderSettings.enablementDeepLinks == expected)
    }
}
