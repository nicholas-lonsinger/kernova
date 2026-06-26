import AppKit
import Foundation
import KernovaKit
import Testing
import UniformTypeIdentifiers

@testable import Kernova

/// Exercises `ClipboardContentViewController.hostPasteboardItems` — the pure
/// "Copy to Mac" grouping/staging step that turns the buffer into one
/// `PasteboardItemSpec` per inline-content block plus one per file payload.
///
/// Each spec promises a set of types and serves their bytes lazily through
/// `provide`; the tests drive that closure directly, so they cover both the
/// grouping and the on-demand read without touching a real `NSPasteboard`.
@Suite("ClipboardContentViewController host write-back")
struct ClipboardHostPasteboardItemsTests {
    private func makeStaging() -> ClipboardFileStaging {
        ClipboardFileStaging(
            label: "hostwrite-test-\(UUID().uuidString)",
            tempRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true))
    }

    /// The file URL a spec serves for `.fileURL`, or `nil` when it promises none.
    private func fileURL(in spec: ClipboardContentViewController.PasteboardItemSpec) -> URL? {
        spec.provide(.fileURL)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(URL.init(string:))
    }

    @Test("a plain-text inline copy promises its text UTI and serves bytes lazily")
    func inlineTextServedLazily() async {
        let staging = makeStaging()
        defer { staging.sweep() }

        let content = ClipboardContent(text: "hello world")
        let specs = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(specs.count == 1)
        let spec = specs[0]
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        #expect(spec.types == [textType])
        // The bytes are produced on demand by the provider closure.
        #expect(spec.provide(textType) == Data("hello world".utf8))
        // A type this item never promised serves nothing.
        #expect(spec.provide(.fileURL) == nil)
    }

    @Test("two file payloads produce two items, each promising exactly one file URL")
    func twoFilesTwoItems() async throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("alpha".utf8), filename: "a.txt"),
            .init(uti: UTType.plainText.identifier, data: Data("beta".utf8), filename: "b.txt"),
        ])
        let specs = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(specs.count == 2)
        // A non-image file is file-only: exactly one `.fileURL`, no inline bytes.
        for spec in specs {
            #expect(spec.types == [.fileURL])
        }
        let urlA = try #require(fileURL(in: specs[0]))
        let urlB = try #require(fileURL(in: specs[1]))
        #expect(urlA.lastPathComponent == "a.txt")
        #expect(urlB.lastPathComponent == "b.txt")
        #expect(try Data(contentsOf: urlA) == Data("alpha".utf8))
        #expect(try Data(contentsOf: urlB) == Data("beta".utf8))
    }

    @Test("an image-file item promises both its inline image bytes and a file URL")
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
        let specs = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(specs.count == 1)
        let spec = specs[0]
        let pngType = NSPasteboard.PasteboardType(UTType.png.identifier)
        #expect(Set(spec.types) == [pngType, .fileURL])
        // The inline image bytes are served lazily; the file URL stages the same.
        #expect(spec.provide(pngType) == png)
        let url = try #require(fileURL(in: spec))
        #expect(url.lastPathComponent == "photo.png")
        #expect(try Data(contentsOf: url) == png)
    }

    @Test("an image file's image bytes survive deletion of its original transient file")
    func imageFileImageBytesReadFromDurableCopy() async throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
        let png = try #require(rep.representation(using: .png, properties: [:]))

        // A file payload streams to disk, so it reaches hostPasteboardItems as a
        // `.file` source whose URL points into the service's TRANSIENT staging —
        // not resident bytes. Model that with a real file we delete below.
        let transient = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-photo.png")
        try png.write(to: transient)
        let content = ClipboardContent(representations: [
            .init(
                uti: UTType.png.identifier, fileURL: transient, byteCount: png.count,
                filename: "photo.png")
        ])

        let specs = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)
        #expect(specs.count == 1)
        let spec = specs[0]
        let pngType = NSPasteboard.PasteboardType(UTType.png.identifier)
        #expect(Set(spec.types) == [pngType, .fileURL])

        // Simulate the VM stopping: the service's transient staging is swept, so
        // the representation's own file URL is gone. The promise is kept alive by
        // the registry past window close, so a later paste of the image flavor must
        // still serve the bytes — from the durably-adopted staged copy, not the
        // swept original. (Reading `representation.fileURL` lazily would vend nil.)
        try FileManager.default.removeItem(at: transient)

        #expect(spec.provide(pngType) == png)
        let url = try #require(fileURL(in: spec))
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
        let specs = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(specs.count == 2)
        // First item is the inline block (the text UTI, no file URL).
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        #expect(specs[0].types == [textType])
        #expect(specs[0].provide(textType) == Data("inline text".utf8))
        #expect(fileURL(in: specs[0]) == nil)
        // Second item is the file (a file URL only).
        #expect(specs[1].types == [.fileURL])
        #expect(try #require(fileURL(in: specs[1])).lastPathComponent == "f.txt")
    }

    @Test("same-named files get distinct staged URLs")
    func sameNamedFilesDistinctURLs() async throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("one".utf8), filename: "dup.txt"),
            .init(uti: UTType.plainText.identifier, data: Data("two".utf8), filename: "dup.txt"),
        ])
        let specs = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(specs.count == 2)
        let urlA = try #require(fileURL(in: specs[0]))
        let urlB = try #require(fileURL(in: specs[1]))
        #expect(urlA != urlB)
        // Each file keeps its own contents (no collapse onto one path).
        #expect(try Data(contentsOf: urlA) == Data("one".utf8))
        #expect(try Data(contentsOf: urlB) == Data("two".utf8))
    }

    @Test("a directory payload is extracted into a real folder on the pasteboard")
    func directoryPayloadExtracted() async throws {
        let fm = FileManager.default
        let staging = makeStaging()
        defer { staging.sweep() }

        // Build a source tree, archive it (mirroring what the receiver staged),
        // and point a directory rep at the `.aar`.
        let src = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Project", isDirectory: true)
        try fm.createDirectory(
            at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "readme".write(
            to: src.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "nested".write(
            to: src.appendingPathComponent("sub/n.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: src.deletingLastPathComponent()) }

        let archive = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).aar")
        try ClipboardDirectoryArchive.archive(directoryAt: src, to: archive)
        defer { try? fm.removeItem(at: archive) }
        let size = try #require(fm.attributesOfItem(atPath: archive.path)[.size] as? Int)

        let content = ClipboardContent(representations: [
            .init(
                uti: UTType.folder.identifier, fileURL: archive, byteCount: size,
                filename: "Project", isDirectory: true)
        ])
        let specs = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)

        #expect(specs.count == 1)
        // A directory is file-only: a single `.fileURL`, no inline bytes.
        #expect(specs[0].types == [.fileURL])
        let dirURL = try #require(fileURL(in: specs[0]))
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: dirURL.path, isDirectory: &isDir) && isDir.boolValue)
        // The pasted folder keeps its exact name and contains the extracted tree.
        #expect(dirURL.lastPathComponent == "Project")
        #expect(
            try String(contentsOf: dirURL.appendingPathComponent("README.md"), encoding: .utf8)
                == "readme")
        #expect(
            try String(contentsOf: dirURL.appendingPathComponent("sub/n.txt"), encoding: .utf8)
                == "nested")
    }

    @Test("a directory payload whose archive can't be extracted is dropped (no item)")
    func directoryExtractionFailureDropsItem() async throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        // A directory rep pointing at a non-existent `.aar` — extraction fails, so
        // no spec is produced. copyToMac counts this shortfall as a dropped
        // payload and warns instead of claiming success.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-missing.aar")
        let content = ClipboardContent(representations: [
            .init(
                uti: UTType.folder.identifier, fileURL: missing, byteCount: 100, filename: "Gone",
                isDirectory: true)
        ])
        let specs = await ClipboardContentViewController.hostPasteboardItems(
            for: content, generation: 1, staging: staging)
        #expect(specs.isEmpty)
    }
}
