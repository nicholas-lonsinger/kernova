import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import KernovaCore

@Suite("ClipboardContent AppKit helpers", .caseScoped)
struct ClipboardContentAppKitTests {
    // `shouldInlineOnPasteboard` moved to KernovaKit (shared by host + guest);
    // its cases live in `ClipboardRepresentationPasteboardTests` in the package.

    // MARK: - filePayloads / richTextRepresentation

    @Test("filePayloads and the inline remainder partition the representations")
    func partitionComplementary() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("x".utf8), filename: "a.txt"),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("inline".utf8)),
        ])
        #expect(content.filePayloads.count == 1)
        #expect(content.filePayloads.allSatisfy { !$0.filename.isEmpty })
        // The complement is exactly the inline set — no representation is both,
        // and none is neither.
        let inline = content.representations.filter { $0.filename.isEmpty }
        #expect(inline.count == 1)
        #expect(content.filePayloads.count + inline.count == content.representations.count)
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
        // The bundle form `com.apple.rtfd` is not modeled — it never
        // appears as an inline pasteboard flavor (the flat form does).
        #expect(!UTType.rtfd.conformsToRTFFamily)
    }
}
