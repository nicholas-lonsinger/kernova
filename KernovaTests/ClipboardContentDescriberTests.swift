import AppKit
import Foundation
import KernovaProtocol
import Testing
import UniformTypeIdentifiers

@testable import Kernova

@Suite("ClipboardContentDescriber")
struct ClipboardContentDescriberTests {
    /// Real encoded PNG so `imagePixelSize` has a header to read.
    private func makePNG(width: Int, height: Int) throws -> Data {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test("empty content reads Empty")
    func emptyIndicator() {
        #expect(ClipboardContentDescriber.indicatorText(for: .empty) == "Empty")
    }

    @Test("plain text indicator is name · size")
    func textIndicator() {
        let content = ClipboardContent(text: "hello")
        let size = DataFormatters.formatBytes(UInt64(content.totalByteCount))
        #expect(ClipboardContentDescriber.indicatorText(for: content) == "Plain text · \(size)")
    }

    @Test("extra representations are disclosed in the indicator")
    func extraRepsDisclosed() {
        let content = ClipboardContent(representations: [
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
            .init(uti: UTType.rtf.identifier, data: Data("{\\rtf1}".utf8)),
            .init(uti: UTType.html.identifier, data: Data("<b>x</b>".utf8)),
        ])
        let size = DataFormatters.formatBytes(UInt64(content.totalByteCount))
        #expect(
            ClipboardContentDescriber.indicatorText(for: content)
                == "Plain text + 2 more · \(size)")
    }

    @Test("image indicator includes pixel dimensions")
    func imageIndicator() throws {
        let png = try makePNG(width: 12, height: 7)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.png.identifier, data: png)
        ])
        let name = ClipboardContentDescriber.displayName(forUTI: UTType.png.identifier)
        let size = DataFormatters.formatBytes(UInt64(content.totalByteCount))
        #expect(
            ClipboardContentDescriber.indicatorText(for: content)
                == "\(name) · 12 × 7 · \(size)")
    }

    @Test("summary indicator uses the first representation's display name")
    func summaryIndicator() {
        let content = ClipboardContent(representations: [
            .init(uti: "com.example.custom-blob", data: Data(count: 16))
        ])
        let size = DataFormatters.formatBytes(UInt64(16))
        #expect(
            ClipboardContentDescriber.indicatorText(for: content)
                == "com.example.custom-blob · \(size)")
    }

    @Test("displayName falls back to the raw identifier for unknown UTIs")
    func displayNameFallback() {
        #expect(
            ClipboardContentDescriber.displayName(forUTI: "com.example.custom-blob")
                == "com.example.custom-blob")
        // Registered types resolve to a human-readable description.
        #expect(ClipboardContentDescriber.displayName(forUTI: UTType.png.identifier) != UTType.png.identifier)
    }

    @Test("summary rows cap at the limit with an overflow line")
    func summaryRowsCap() {
        let representations = (0..<8).map { index in
            ClipboardContent.Representation(
                uti: "com.example.type\(index)", data: Data(count: index + 1))
        }
        let rows = ClipboardContentDescriber.summaryRows(for: representations)
        #expect(rows.count == ClipboardContentDescriber.maxSummaryRows + 1)
        #expect(rows.last == "and 3 more")
        #expect(rows.first?.hasPrefix("com.example.type0 — ") == true)
    }

    @Test("imagePixelSize returns nil for non-image bytes")
    func pixelSizeNilForGarbage() {
        #expect(ClipboardContentDescriber.imagePixelSize(data: Data("not an image".utf8)) == nil)
    }
}
