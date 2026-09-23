import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("ClipboardRichTextPreviewView Tests", .admissionGated)
@MainActor
struct ClipboardRichTextPreviewViewTests {
    /// How the source colored the previewed text.
    enum SourceColor: CaseIterable, Sendable {
        /// No foreground color of its own.
        case none
        /// An explicit black, which the RTF reader keeps.
        case black
    }

    /// RTF for heavy glyphs colored as `source` says, written the way a Cocoa
    /// app writes it to the pasteboard.
    private func rtf(_ source: SourceColor) throws -> Data {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40, weight: .black)
        ]
        if source == .black {
            attributes[.foregroundColor] = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
        let text = NSAttributedString(string: "MMMM", attributes: attributes)
        return try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// The brightness of the pixel `view` draws furthest from its well's own —
    /// the core of a glyph stroke, clear of the antialiased edge.
    private func glyphCoreBrightness(of view: NSView) throws -> CGFloat {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        func brightness(x: Int, y: Int) -> CGFloat? {
            rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent
        }
        // The text container's inset keeps the corner clear of text.
        let well = try #require(brightness(x: 0, y: 0))
        var core = well
        // Every other pixel: a 40-point black-weight stroke is many pixels wide.
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let pixel = brightness(x: x, y: y), abs(pixel - well) > abs(core - well)
                else { continue }
                core = pixel
            }
        }
        try #require(abs(core - well) > 0.1, "the preview drew no text")
        return core
    }

    @Test(
        "Black-drawing text reads on the well in either appearance",
        arguments: [NSAppearance.Name.aqua, .darkAqua], SourceColor.allCases)
    func blackTextReadsOnTheWell(appearance: NSAppearance.Name, source: SourceColor) throws {
        let preview = ClipboardRichTextPreviewView()
        preview.appearance = NSAppearance(named: appearance)
        preview.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        try #require(preview.configure(data: rtf(source), uti: "public.rtf"))
        preview.layoutSubtreeIfNeeded()

        let brightness = try glyphCoreBrightness(of: preview)
        if appearance == .darkAqua {
            #expect(brightness > 0.8, "text on the dark well must draw light")
        } else {
            #expect(brightness < 0.2, "text on the light well draws as the source wrote it")
        }
    }
}
