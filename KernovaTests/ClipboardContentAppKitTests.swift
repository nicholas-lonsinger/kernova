import Foundation
import KernovaKit
import Testing
import UniformTypeIdentifiers

@testable import Kernova

@Suite("ClipboardContent AppKit helpers")
struct ClipboardContentAppKitTests {
    // `shouldInlineOnPasteboard` moved to KernovaKit (shared by host + guest);
    // its cases live in `ClipboardRepresentationPasteboardTests` in the package.

    // MARK: - filePayloads / inlineRepresentations / richTextRepresentation

    @Test("filePayloads returns the filename-tagged representations in order")
    func filePayloadsFound() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("x".utf8), filename: "a.txt"),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("inline".utf8)),
            .init(uti: UTType.png.identifier, data: Data([0x89]), filename: "b.png"),
        ])
        #expect(content.filePayloads.map(\.filename) == ["a.txt", "b.png"])
        #expect(content.filePayloads.first?.filename == "a.txt")
    }

    @Test("filePayloads is empty and inlineRepresentations holds all when none carry a filename")
    func filePayloadsAbsent() {
        let content = ClipboardContent(text: "just text")
        #expect(content.filePayloads.isEmpty)
        #expect(content.inlineRepresentations.count == content.representations.count)
    }

    @Test("filePayloads and inlineRepresentations partition the representations")
    func partitionComplementary() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("x".utf8), filename: "a.txt"),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("inline".utf8)),
        ])
        #expect(content.filePayloads.count == 1)
        #expect(content.inlineRepresentations.count == 1)
        #expect(content.inlineRepresentations.allSatisfy { $0.filename.isEmpty })
    }

    @Test("richTextRepresentation finds an inline RTF rep")
    func richTextFound() {
        let rtf = Data("{\\rtf1}".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.rtf.identifier, data: rtf),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
        ])
        #expect(content.richTextRepresentation?.inMemoryData == rtf)
    }

    @Test("a copied .rtf file is not treated as inline rich text")
    func rtfFileIsNotRichText() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.rtf.identifier, data: Data("{\\rtf1}".utf8), filename: "styled.rtf")
        ])
        #expect(content.richTextRepresentation == nil)
    }

    @Test("richTextRepresentation prefers flat-RTFD over plain RTF")
    func richTextPrefersFlatRTFD() {
        // The image-bearing flat-RTFD must win over the text-only plain RTF that
        // coexists on the pasteboard, regardless of order.
        let rtfd = Data("rtfd-with-image".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.rtf.identifier, data: Data("{\\rtf1}".utf8)),
            .init(uti: UTType.flatRTFD.identifier, data: rtfd),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
        ])
        #expect(content.richTextRepresentation?.uti == UTType.flatRTFD.identifier)
        #expect(content.richTextRepresentation?.inMemoryData == rtfd)
    }

    @Test("richTextRepresentation finds flat-RTFD with no plain-RTF sibling")
    func richTextFindsFlatRTFDAlone() {
        let rtfd = Data("rtfd".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.flatRTFD.identifier, data: rtfd),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
        ])
        #expect(content.richTextRepresentation?.uti == UTType.flatRTFD.identifier)
    }

    @Test("a copied .rtfd file is not treated as inline rich text")
    func rtfdFileIsNotRichText() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.flatRTFD.identifier, data: Data("rtfd".utf8), filename: "styled.rtfd")
        ])
        #expect(content.richTextRepresentation == nil)
    }

    // MARK: - UTType RTF-family helpers

    @Test("flat-RTFD is an RTF-family flavor that needs the RTFD document type")
    func flatRTFDIsRichAndNeedsRTFD() {
        #expect(UTType.flatRTFD.conformsToRTFFamily)
        #expect(UTType.flatRTFD.needsRTFDDocumentType)
        // The bundle form `com.apple.rtfd` is intentionally not modeled — it never
        // appears as an inline pasteboard flavor (the flat form does).
        #expect(!UTType.rtfd.conformsToRTFFamily)
    }

    @Test("plain RTF is an RTF-family flavor but decodes as plain RTF, not RTFD")
    func plainRTFIsRichButNotRTFD() {
        #expect(UTType.rtf.conformsToRTFFamily)
        #expect(!UTType.rtf.needsRTFDDocumentType)
    }

    @Test("non-rich types are not RTF-family")
    func nonRichTypesAreNotRTFFamily() {
        #expect(!UTType.plainText.conformsToRTFFamily)
        #expect(!UTType.png.conformsToRTFFamily)
        #expect(!UTType.html.conformsToRTFFamily)
    }
}
