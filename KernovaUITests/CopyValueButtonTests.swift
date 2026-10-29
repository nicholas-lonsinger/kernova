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

    @Test("A copy writes the value and swaps the glyph for the checkmark")
    func copySwapsInTheCheckmark() {
        defer { pasteboard.releaseGlobally() }
        let button = makeButton(hold: .seconds(testWaitBackstop))
        let copyGlyph = button.image

        button.performClick(nil)

        #expect(pasteboard.string(forType: .string) == "192.168.64.10")
        #expect(button.showsConfirmation)
        #expect(button.image !== copyGlyph)
    }

    @Test("The copy glyph returns once the hold passes")
    func copyGlyphReturnsOnceTheHoldPasses() async throws {
        defer { pasteboard.releaseGlobally() }
        let button = makeButton(hold: .zero)
        let copyGlyph = button.image

        button.performClick(nil)

        try await waitUntil { !button.showsConfirmation && button.image === copyGlyph }
    }

    @Test("The checkmark leaves with the value it confirmed")
    func checkmarkLeavesWithItsValue() {
        defer { pasteboard.releaseGlobally() }
        let button = makeButton(hold: .seconds(testWaitBackstop))
        let copyGlyph = button.image
        button.performClick(nil)

        button.value = "192.168.64.11"

        #expect(!button.showsConfirmation)
        #expect(button.image === copyGlyph)
    }

    @Test("The checkmark keeps the copy glyph's size, so the value beside it stays put")
    func checkmarkKeepsTheCopyGlyphsSize() {
        defer { pasteboard.releaseGlobally() }
        let button = makeButton(hold: .seconds(testWaitBackstop))
        let restingSize = button.intrinsicContentSize

        button.performClick(nil)

        #expect(button.showsConfirmation)
        #expect(button.intrinsicContentSize == restingSize)
    }
}
