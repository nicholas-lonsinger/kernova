import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("NSColor.withDynamicAlpha Tests", .caseScoped)
struct NSColorExtensionsTests {
    private static let bases: [NSColor] = [.systemOrange, .secondaryLabelColor]

    private func resolved(_ color: NSColor, in name: NSAppearance.Name) throws -> NSColor {
        var result: NSColor?
        try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        return try #require(result)
    }

    @Test(
        "A tint built under one appearance resolves to the base's value under the other",
        arguments: bases, [(NSAppearance.Name.aqua, NSAppearance.Name.darkAqua), (.darkAqua, .aqua)])
    func followsAppearanceItWasNotBuiltIn(base: NSColor, appearances: (NSAppearance.Name, NSAppearance.Name)) throws {
        let (builtIn, drawnIn) = appearances
        var built: NSColor?
        try #require(NSAppearance(named: builtIn)).performAsCurrentDrawingAppearance {
            built = base.withDynamicAlpha(0.1)
        }
        let tinted = try resolved(try #require(built), in: drawnIn)
        let expected = try resolved(base, in: drawnIn)

        #expect(abs(tinted.redComponent - expected.redComponent) < 0.001)
        #expect(abs(tinted.greenComponent - expected.greenComponent) < 0.001)
        #expect(abs(tinted.blueComponent - expected.blueComponent) < 0.001)
        #expect(abs(tinted.alphaComponent - 0.1) < 0.001)
    }

    @Test("A tint resolves differently in light and dark", arguments: bases)
    func differsBetweenAppearances(base: NSColor) throws {
        let tinted = base.withDynamicAlpha(0.1)
        let light = try resolved(tinted, in: .aqua)
        let dark = try resolved(tinted, in: .darkAqua)

        #expect(light != dark)
    }
}
