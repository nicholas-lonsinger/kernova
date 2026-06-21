import AppKit
import Foundation
import KernovaProtocol
import Testing
import UniformTypeIdentifiers

@testable import Kernova

/// Exercises `ClipboardContentViewController.hostPasteboardItems` — the pure
/// "Copy to Mac" grouping/staging step that turns the buffer into one
/// `NSPasteboardItem` per inline-content block plus one per file payload.
@Suite("ClipboardContentViewController host write-back")
struct ClipboardHostPasteboardItemsTests {
    private func makeStaging() -> ClipboardFileStaging {
        ClipboardFileStaging(
            label: "hostwrite-test-\(UUID().uuidString)",
            tempRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true))
    }

    private func fileURL(
        in item: [(type: NSPasteboard.PasteboardType, data: Data)]
    ) -> URL? {
        item.first { $0.type == .fileURL }
            .flatMap { String(data: $0.data, encoding: .utf8) }
            .flatMap(URL.init(string:))
    }

    @Test("two file payloads produce two items, each carrying exactly one file URL")
    func twoFilesTwoItems() async throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("alpha".utf8), filename: "a.txt"),
            .init(uti: UTType.plainText.identifier, data: Data("beta".utf8), filename: "b.txt"),
        ])
        let items = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(items.count == 2)
        // A non-image file is file-only: exactly one `.fileURL`, no inline bytes.
        for item in items {
            #expect(item.map { $0.type } == [.fileURL])
        }
        let urlA = try #require(fileURL(in: items[0]))
        let urlB = try #require(fileURL(in: items[1]))
        #expect(urlA.lastPathComponent == "a.txt")
        #expect(urlB.lastPathComponent == "b.txt")
        #expect(try Data(contentsOf: urlA) == Data("alpha".utf8))
        #expect(try Data(contentsOf: urlB) == Data("beta".utf8))
    }

    @Test("an image-file item carries both its inline image bytes and a file URL")
    func imageFileItemCarriesBoth() async throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let content = ClipboardContent(representations: [
            .init(uti: UTType.png.identifier, data: png, filename: "photo.png")
        ])
        let items = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(items.count == 1)
        let item = items[0]
        #expect(
            Set(item.map { $0.type })
                == [NSPasteboard.PasteboardType(UTType.png.identifier), .fileURL])
        // The inline image bytes are the PNG; the file URL stages the same bytes.
        let inline = try #require(
            item.first { $0.type == NSPasteboard.PasteboardType(UTType.png.identifier) }?.data)
        #expect(inline == png)
        let url = try #require(fileURL(in: item))
        #expect(url.lastPathComponent == "photo.png")
        #expect(try Data(contentsOf: url) == png)
    }

    @Test("inline content and a file produce one inline item plus one file item")
    func inlinePlusFile() async throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let content = ClipboardContent(representations: [
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("inline text".utf8)),
            .init(uti: UTType.plainText.identifier, data: Data("file body".utf8), filename: "f.txt"),
        ])
        let items = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(items.count == 2)
        // First item is the inline block (the text UTI, no file URL).
        #expect(items[0].map { $0.type } == [NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)])
        #expect(fileURL(in: items[0]) == nil)
        // Second item is the file (a file URL only).
        #expect(items[1].map { $0.type } == [.fileURL])
        #expect(try #require(fileURL(in: items[1])).lastPathComponent == "f.txt")
    }

    @Test("same-named files get distinct staged URLs")
    func sameNamedFilesDistinctURLs() async throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("one".utf8), filename: "dup.txt"),
            .init(uti: UTType.plainText.identifier, data: Data("two".utf8), filename: "dup.txt"),
        ])
        let items = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(items.count == 2)
        let urlA = try #require(fileURL(in: items[0]))
        let urlB = try #require(fileURL(in: items[1]))
        #expect(urlA != urlB)
        // Each file keeps its own contents (no collapse onto one path).
        #expect(try Data(contentsOf: urlA) == Data("one".utf8))
        #expect(try Data(contentsOf: urlB) == Data("two".utf8))
    }
}
