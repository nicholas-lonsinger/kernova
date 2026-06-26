import AppKit
import Foundation
import KernovaKit
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

    @Test("the hash-free forPlainText indicator matches the full-content indicator")
    func plainTextIndicatorMatchesFullContent() {
        // The per-keystroke editor path uses forPlainText; it must render exactly
        // what the full ClipboardContent path would for that single text rep.
        let large = String(repeating: "x", count: 5000)
        for text in ["", "hello", "héllo · ünïcode", large] {
            let viaText = ClipboardContentDescriber.indicatorText(forPlainText: text)
            let viaContent = ClipboardContentDescriber.indicatorText(for: ClipboardContent(text: text))
            #expect(viaText == viaContent, "mismatch for \(text.count)-char string")
        }
    }

    @Test("extra representations are disclosed in the indicator")
    func extraRepsDisclosed() {
        // Plain text wins the preview; the two non-rich siblings are disclosed
        // as "+ 2 more" (custom blobs, so the rich-text rule doesn't fire).
        let content = ClipboardContent(representations: [
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
            .init(uti: "com.example.a", data: Data([1, 2])),
            .init(uti: "com.example.b", data: Data([3, 4])),
        ])
        let size = DataFormatters.formatBytes(UInt64(content.totalByteCount))
        #expect(
            ClipboardContentDescriber.indicatorText(for: content)
                == "Plain text + 2 more · \(size)")
    }

    @Test("rich text indicator uses the RTF type name")
    func richTextIndicator() {
        let rtf = Data("{\\rtf1}".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.rtf.identifier, data: rtf),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
        ])
        let name = ClipboardContentDescriber.displayName(forUTI: UTType.rtf.identifier)
        let size = DataFormatters.formatBytes(UInt64(content.totalByteCount))
        // RTF + a coexisting plain-text sibling → "<RTF name> + 1 more · size".
        #expect(
            ClipboardContentDescriber.indicatorText(for: content) == "\(name) + 1 more · \(size)")
    }

    @Test("file indicator is name · type · size")
    func fileIndicator() {
        let bytes = Data("hello".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: bytes, filename: "note.txt")
        ])
        let typeName = ClipboardContentDescriber.displayName(forUTI: UTType.plainText.identifier)
        let size = DataFormatters.formatBytes(UInt64(content.totalByteCount))
        #expect(
            ClipboardContentDescriber.indicatorText(for: content)
                == "note.txt · \(typeName) · \(size)")
    }

    @Test("multi-file indicator is a count and total size (no per-rep tail)")
    func multipleFilesIndicator() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("aa".utf8), filename: "a.txt"),
            .init(uti: UTType.png.identifier, data: Data([0x89, 0x50]), filename: "b.png"),
        ])
        let size = DataFormatters.formatBytes(UInt64(content.totalByteCount))
        #expect(ClipboardContentDescriber.indicatorText(for: content) == "2 files · \(size)")
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

    @Test("file-backed image indicator includes pixel dimensions read from disk")
    func fileBackedImageIndicator() throws {
        // The user-reported path: a copied image *file* (bytes on disk, no
        // resident data) must read its dimensions from the file header and render
        // like an inline image — "type · W × H · size" — not a bare file chip.
        let png = try makePNG(width: 12, height: 7)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let content = ClipboardContent(representations: [
            .init(uti: UTType.png.identifier, fileURL: url, byteCount: png.count, filename: "photo.png")
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

    @Test("imagePixelSize(url:) reads dimensions from a file-backed image header")
    func pixelSizeFromURL() throws {
        let png = try makePNG(width: 20, height: 9)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ClipboardContentDescriber.imagePixelSize(url: url) == CGSize(width: 20, height: 9))
    }

    @Test("imagePixelSize(url:) returns nil for a missing file")
    func pixelSizeURLNilForMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-does-not-exist.png")
        #expect(ClipboardContentDescriber.imagePixelSize(url: missing) == nil)
    }
}
