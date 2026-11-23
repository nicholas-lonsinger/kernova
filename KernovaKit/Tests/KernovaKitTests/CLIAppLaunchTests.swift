import AppKit
import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// What the tool resolves as the app to start, how it asks for it, and how long
/// it waits for it — all decided without driving `NSWorkspace`, which no test
/// does.
@Suite("CLI app launch", .caseScoped)
struct CLIAppLaunchTests {
    private func locate(_ path: String) -> String? {
        EnclosingAppBundle.locate(executable: URL(fileURLWithPath: path))?.path
    }

    // MARK: - Launch configuration

    /// An open that may reuse a running instance takes any copy sharing the
    /// bundle identifier, so this copy would never start beside another.
    @Test("The launch asks for a new process of the copy, hidden and not activated")
    func launchAsksForANewHiddenInstance() {
        let configuration = AppLaunch.configuration

        #expect(configuration.createsNewApplicationInstance)
        #expect(configuration.hides)
        #expect(!configuration.activates)
        #expect(!configuration.addsToRecentItems)
    }
}
