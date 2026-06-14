import Foundation
import KernovaProtocol
import Testing
import UniformTypeIdentifiers

@testable import Kernova

@Suite("ClipboardContent AppKit helpers")
struct ClipboardContentAppKitTests {
    // MARK: - shouldInlineOnPasteboard

    @Test("non-file content is inlined")
    func nonFileInlines() {
        let rep = ClipboardContent.Representation(
            uti: ClipboardContent.utf8TextUTI, data: Data("hi".utf8))
        #expect(rep.shouldInlineOnPasteboard)
    }

    @Test("an image file payload is inlined (so it shows in place)")
    func imageFileInlines() {
        let rep = ClipboardContent.Representation(
            uti: UTType.png.identifier, data: Data([0x89]), filename: "photo.png")
        #expect(rep.shouldInlineOnPasteboard)
    }

    @Test("a non-image file payload is file-only, not inlined")
    func nonImageFileNotInlined() {
        let rep = ClipboardContent.Representation(
            uti: UTType.plainText.identifier, data: Data("x".utf8), filename: "note.txt")
        #expect(!rep.shouldInlineOnPasteboard)
    }

    // MARK: - filePayload / richTextRepresentation

    @Test("filePayload returns the filename-tagged representation")
    func filePayloadFound() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("x".utf8), filename: "note.txt")
        ])
        #expect(content.filePayload?.filename == "note.txt")
    }

    @Test("filePayload is nil when no representation carries a filename")
    func filePayloadAbsent() {
        let content = ClipboardContent(text: "just text")
        #expect(content.filePayload == nil)
    }

    @Test("richTextRepresentation finds an inline RTF rep")
    func richTextFound() {
        let rtf = Data("{\\rtf1}".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.rtf.identifier, data: rtf),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
        ])
        #expect(content.richTextRepresentation?.data == rtf)
    }

    @Test("a copied .rtf file is not treated as inline rich text")
    func rtfFileIsNotRichText() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.rtf.identifier, data: Data("{\\rtf1}".utf8), filename: "styled.rtf")
        ])
        #expect(content.richTextRepresentation == nil)
    }
}
