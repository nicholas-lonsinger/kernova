import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("makeStatusDot Tests", .caseScoped)
@MainActor
struct StatusDotTests {
    @Test("A status dot beside its label exposes only the label to accessibility")
    func dotIsHiddenFromAccessibility() {
        let row = NSStackView(views: [makeStatusDot(), NSTextField(labelWithString: "Connected")])

        let elements = row.unignoredAccessibilityElements
        #expect(elements.map { $0.accessibilityRole() } == [.staticText])
        #expect(elements.first?.accessibilityValue() as? String == "Connected")
    }
}
