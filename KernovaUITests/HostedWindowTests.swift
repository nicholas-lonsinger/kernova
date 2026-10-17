import AppKit
import Testing

@testable import KernovaUI

@MainActor
struct HostedWindowTests {
    @Test func runsInTheBackgroundTestHost() {
        #expect(Bundle.main.bundleIdentifier == "app.kernova.testhost")
        #expect(NSApp.isRunning)
        #expect(!NSApp.isActive)
    }

    @Test func parkedWindowFocusesItsField() {
        let controller = TextEntryViewController()
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        defer { window.close() }

        #expect(controller.focusField())
        #expect((window.firstResponder as? NSTextView)?.delegate === controller.field)
    }
}
