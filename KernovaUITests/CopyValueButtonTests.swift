import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaUI

@Suite("Copy Value Button Tests", .caseScoped)
@MainActor
struct CopyValueButtonTests {
    /// Fresh uniquely-named pasteboard so tests never touch `.general`.
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("kernova-test-\(UUID().uuidString)"))

    private func makeButton(hold: Duration) -> CopyValueButton {
        CopyValueButton(
            name: "Copy IP Address", value: "192.168.64.10", pasteboard: pasteboard,
            confirmationHold: hold)
    }

    @Test("A copy writes the value and shows the checkmark")
    func copyShowsTheCheckmark() {
        defer { pasteboard.releaseGlobally() }
        let button = makeButton(hold: .seconds(testWaitBackstop))

        button.performClick(nil)

        #expect(pasteboard.string(forType: .string) == "192.168.64.10")
        #expect(button.showsConfirmation)
    }

    @Test("The checkmark goes once its hold passes")
    func checkmarkGoesOnceItsHoldPasses() async throws {
        defer { pasteboard.releaseGlobally() }
        let button = makeButton(hold: .zero)

        button.performClick(nil)

        try await waitUntil { !button.showsConfirmation }
    }

    @Test("The checkmark leaves with the value it confirmed")
    func checkmarkLeavesWithItsValue() {
        defer { pasteboard.releaseGlobally() }
        let button = makeButton(hold: .seconds(testWaitBackstop))
        button.performClick(nil)

        button.value = "192.168.64.11"

        #expect(!button.showsConfirmation)
    }

    @Test("A click on the glyph lands on the button")
    func clickOnTheGlyphLandsOnTheButton() {
        defer { pasteboard.releaseGlobally() }
        let button = makeButton(hold: .seconds(testWaitBackstop))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        container.addSubview(button)
        button.frame = NSRect(origin: NSPoint(x: 10, y: 10), size: button.fittingSize)
        container.layoutSubtreeIfNeeded()

        #expect(container.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button)
    }
}
