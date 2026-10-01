import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("NSColor.withDynamicAlpha Tests", .caseScoped)
struct NSColorExtensionsTests {
    @Test(
        "A tint built under one appearance resolves to the base's value under the other",
        arguments: [NSColor.systemOrange, .secondaryLabelColor],
        [(NSAppearance.Name.aqua, NSAppearance.Name.darkAqua), (.darkAqua, .aqua)])
    func followsAppearanceItWasNotBuiltIn(base: NSColor, appearances: (NSAppearance.Name, NSAppearance.Name)) throws {
        let (builtIn, drawnIn) = appearances
        var built: NSColor?
        try #require(NSAppearance(named: builtIn)).performAsCurrentDrawingAppearance {
            built = base.withDynamicAlpha(0.1)
        }
        let tinted = try #require(built).resolvedSRGB(in: drawnIn)
        let expected = try base.resolvedSRGB(in: drawnIn)

        #expect(abs(tinted.redComponent - expected.redComponent) < 0.001)
        #expect(abs(tinted.greenComponent - expected.greenComponent) < 0.001)
        #expect(abs(tinted.blueComponent - expected.blueComponent) < 0.001)
        #expect(abs(tinted.alphaComponent - 0.1) < 0.001)
    }
}
