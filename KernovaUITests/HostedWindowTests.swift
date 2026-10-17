import AppKit
import Testing

@MainActor
struct HostedWindowTests {
    @Test func runsInTheBackgroundTestHost() {
        #expect(Bundle.main.bundleIdentifier == "app.kernova.testhost")
        #expect(NSApp.isRunning)
        #expect(!NSApp.isActive)
    }
}
