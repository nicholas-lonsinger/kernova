import AppKit
import Foundation
import KernovaProtocol
import Testing
import UniformTypeIdentifiers

@testable import Kernova

@Suite("ClipboardPasteboardIntake")
@MainActor
struct ClipboardPasteboardIntakeTests {
    /// Fresh uniquely-named pasteboard so tests never touch `.general`.
    private func makeScratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("kernova-test-\(UUID().uuidString)"))
    }

    private func write(
        _ representations: [(uti: String, data: Data)], to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for representation in representations {
            item.setData(
                representation.data,
                forType: NSPasteboard.PasteboardType(rawValue: representation.uti))
        }
        pasteboard.writeObjects([item])
    }

    private func makeTempFile(name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-intake-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func makePNG() throws -> Data {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - Generic pasteboard reads

    @Test("text on the pasteboard becomes text content")
    func textIntake() {
        let pasteboard = makeScratchPasteboard()
        write([(uti: ClipboardContent.utf8TextUTI, data: Data("hello".utf8))], to: pasteboard)

        guard
            case .content(let content, let note) = ClipboardPasteboardIntake.read(
                from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected content")
            return
        }
        #expect(content.text == "hello")
        #expect(note == nil)
    }

    @Test("multiple representations are all taken, in order")
    func multiRepIntake() throws {
        let pasteboard = makeScratchPasteboard()
        let png = try makePNG()
        write(
            [
                (uti: UTType.png.identifier, data: png),
                (uti: ClipboardContent.utf8TextUTI, data: Data("caption".utf8)),
            ], to: pasteboard)

        guard
            case .content(let content, _) = ClipboardPasteboardIntake.read(
                from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected content")
            return
        }
        #expect(
            content.representations.map(\.uti) == [
                UTType.png.identifier, ClipboardContent.utf8TextUTI,
            ])
        #expect(content.representations.first?.data == png)
    }

    @Test("empty pasteboard is rejected")
    func emptyPasteboardRejected() {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()

        guard case .rejected = ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected rejection for empty pasteboard")
            return
        }
    }

    @Test("text-only transport takes only the text representation")
    func textOnlyTransport() throws {
        let pasteboard = makeScratchPasteboard()
        let png = try makePNG()
        write(
            [
                (uti: UTType.png.identifier, data: png),
                (uti: ClipboardContent.utf8TextUTI, data: Data("caption".utf8)),
            ], to: pasteboard)

        guard
            case .content(let content, _) = ClipboardPasteboardIntake.read(
                from: pasteboard, allowsBinary: false)
        else {
            Issue.record("Expected content")
            return
        }
        #expect(content.representations.map(\.uti) == [ClipboardContent.utf8TextUTI])
    }

    @Test("text-only transport rejects image-only content with a clear message")
    func textOnlyTransportRejectsImage() throws {
        let pasteboard = makeScratchPasteboard()
        write([(uti: UTType.png.identifier, data: try makePNG())], to: pasteboard)

        guard
            case .rejected(let message) = ClipboardPasteboardIntake.read(
                from: pasteboard, allowsBinary: false)
        else {
            Issue.record("Expected rejection")
            return
        }
        #expect(message == ClipboardPasteboardIntake.textOnlyTransportMessage)
    }

    @Test("filtered-only content is rejected, not silently emptied")
    func filteredOnlyRejected() {
        let pasteboard = makeScratchPasteboard()
        write(
            [(uti: "org.nspasteboard.TransientType", data: Data([1]))], to: pasteboard)

        guard case .rejected = ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected rejection")
            return
        }
    }

    @Test("oversized representation is skipped with a user-visible note")
    func oversizedSkippedWithNote() {
        let pasteboard = makeScratchPasteboard()
        write(
            [
                (
                    uti: UTType.tiff.identifier,
                    data: Data(count: ClipboardSnapshotPolicy.maxRepresentationByteCount + 1)
                ),
                (uti: ClipboardContent.utf8TextUTI, data: Data("small".utf8)),
            ], to: pasteboard)

        guard
            case .content(let content, let note) = ClipboardPasteboardIntake.read(
                from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected content")
            return
        }
        #expect(content.representations.map(\.uti) == [ClipboardContent.utf8TextUTI])
        #expect(note != nil)
    }

    // MARK: - File URL expansion

    @Test("dragged text file becomes text content")
    func textFileIntake() throws {
        let url = try makeTempFile(name: "note.txt", contents: Data("file text".utf8))
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])

        guard
            case .content(let content, _) = ClipboardPasteboardIntake.read(
                from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected content")
            return
        }
        #expect(content.text == "file text")
    }

    @Test("dragged image file becomes an image representation")
    func imageFileIntake() throws {
        let png = try makePNG()
        let url = try makeTempFile(name: "image.png", contents: png)
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])

        guard
            case .content(let content, _) = ClipboardPasteboardIntake.read(
                from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected content")
            return
        }
        #expect(content.representations.count == 1)
        #expect(UTType(content.representations[0].uti)?.conforms(to: .image) == true)
        #expect(content.representations[0].data == png)
    }

    @Test("dragged file of an unsupported type is rejected")
    func unsupportedFileRejected() throws {
        let url = try makeTempFile(name: "blob.bin", contents: Data([0x00, 0x01]))
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])

        guard case .rejected = ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected rejection")
            return
        }
    }

    @Test("read(fileAt:) expands an image file directly — the promise-receipt path")
    func directFileReadImage() throws {
        let png = try makePNG()
        let url = try makeTempFile(name: "promised.png", contents: png)

        guard
            case .content(let content, _) = ClipboardPasteboardIntake.read(
                fileAt: url, allowsBinary: true)
        else {
            Issue.record("Expected content")
            return
        }
        #expect(content.representations.count == 1)
        #expect(content.representations[0].data == png)
    }

    @Test("read(fileAt:) rejects an oversized file before reading it")
    func directFileReadOversizedRejected() throws {
        let url = try makeTempFile(
            name: "huge.png",
            contents: Data(count: ClipboardSnapshotPolicy.maxRepresentationByteCount + 1))

        guard case .rejected = ClipboardPasteboardIntake.read(fileAt: url, allowsBinary: true)
        else {
            Issue.record("Expected rejection")
            return
        }
    }

    @Test("dragged image file on a text-only transport is rejected")
    func imageFileTextOnlyRejected() throws {
        let url = try makeTempFile(name: "image.png", contents: try makePNG())
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])

        guard
            case .rejected(let message) = ClipboardPasteboardIntake.read(
                from: pasteboard, allowsBinary: false)
        else {
            Issue.record("Expected rejection")
            return
        }
        #expect(message == ClipboardPasteboardIntake.textOnlyTransportMessage)
    }
}
