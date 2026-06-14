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

    @Test("dragged text file conveys its name, not its contents")
    func textFileIntake() throws {
        // A copied/dragged .txt is "the file" — only its name crosses, never
        // its inlined text (matching how macOS treats a copied text file).
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
        #expect(content.text == "note.txt")
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

    @Test("dragged non-image file conveys its name, not its contents")
    func nonImageFileConveysName() throws {
        let url = try makeTempFile(name: "blob.bin", contents: Data([0x00, 0x01]))
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
        #expect(content.text == "blob.bin")
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

    // MARK: - Screenshot thumbnail (promised file URL)

    @Test("a promised-file-url on disk is read as the image — the screenshot thumbnail mechanism")
    func promisedFileURLImage() throws {
        // The floating screenshot thumbnail is a promise drag: NO concrete
        // public.file-url, NO inline image bytes — only a promised-file-url
        // pointing at the temp file screencaptureui has already written, plus
        // a path-text fallback. The temp file exists during the drag.
        let png = try makePNG()
        let url = try makeTempFile(name: "Screenshot 2026 at 6.57.png", contents: png)
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(
            url.absoluteString,
            forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
        item.setString(url.path, forType: .string)  // the path-text fallback
        pasteboard.writeObjects([item])

        guard
            case .content(let content, _) = ClipboardPasteboardIntake.read(
                from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected image content")
            return
        }
        #expect(content.representations.count == 1)
        #expect(content.representations[0].data == png)
        // The decisive assertion: the path text must NOT leak as content.
        #expect(content.text == nil)
    }

    @Test("a promise drag with no on-disk file never leaks the path as text")
    func promiseWithoutFileNoPathLeak() {
        // Promise present, but the file isn't on disk and there's no inline
        // image — the path/url text reps are descriptors and must be dropped,
        // so the caller falls through to async promise receipt (a rejection
        // here), never showing the path string.
        let missing = "/var/folders/zz/missing-\(UUID().uuidString)/Screenshot.png"
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(
            "file://" + missing,
            forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
        item.setData(
            Data("public.png".utf8),
            forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"))
        item.setString(missing, forType: .string)
        pasteboard.writeObjects([item])

        guard case .rejected = ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected rejection — the path must not leak as text content")
            return
        }
    }

    @Test("a plain text drag (no file/promise) still becomes text")
    func plainTextDragStillText() {
        // Guard against over-reaching the file-context skip: a genuine text
        // drag has no file/promise types, so the text survives.
        let pasteboard = makeScratchPasteboard()
        write([(uti: ClipboardContent.utf8TextUTI, data: Data("just some text".utf8))], to: pasteboard)

        guard
            case .content(let content, _) = ClipboardPasteboardIntake.read(
                from: pasteboard, allowsBinary: true)
        else {
            Issue.record("Expected text content")
            return
        }
        #expect(content.text == "just some text")
    }
}
