import Foundation
import KernovaProtocol
import Testing
import UniformTypeIdentifiers

@testable import Kernova

@Suite("ClipboardPreviewPolicy")
struct ClipboardPreviewPolicyTests {
    @Test("empty content renders the empty editor")
    func emptyContent() {
        #expect(ClipboardPreviewPolicy.mode(for: .empty) == .empty)
    }

    @Test("small text renders the editor")
    func smallText() {
        let mode = ClipboardPreviewPolicy.mode(for: ClipboardContent(text: "hello"))
        #expect(mode == .text("hello"))
    }

    @Test("text wins over coexisting richer representations")
    func textWinsOverRicher() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.rtf.identifier, data: Data("{\\rtf1}".utf8)),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
            .init(uti: UTType.png.identifier, data: Data([0x89])),
        ])
        #expect(ClipboardPreviewPolicy.mode(for: content) == .text("plain"))
    }

    @Test("image-only content renders the image preview with the preferred UTI")
    func imagePreferredUTI() {
        let pngData = Data([0x89, 0x50])
        let content = ClipboardContent(representations: [
            .init(uti: UTType.tiff.identifier, data: Data([0x4D, 0x4D])),
            .init(uti: UTType.png.identifier, data: pngData),
        ])
        // PNG preferred over TIFF regardless of representation order.
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .image(data: pngData, uti: UTType.png.identifier))
    }

    @Test("image with non-text siblings renders the image preview")
    func imageWithHTMLSibling() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.html.identifier, data: Data("<b>x</b>".utf8)),
            .init(uti: UTType.png.identifier, data: Data([0x89])),
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .image(data: Data([0x89]), uti: UTType.png.identifier))
    }

    @Test("oversized text with no image renders the summary")
    func oversizedTextSummary() {
        let big = String(repeating: "a", count: ClipboardPreviewPolicy.maxEditableTextBytes + 1)
        let content = ClipboardContent(text: big)
        #expect(ClipboardPreviewPolicy.mode(for: content) == .summary(content.representations))
    }

    @Test("text at exactly the limit still renders the editor")
    func textAtLimit() {
        let text = String(repeating: "a", count: ClipboardPreviewPolicy.maxEditableTextBytes)
        #expect(ClipboardPreviewPolicy.mode(for: ClipboardContent(text: text)) == .text(text))
    }

    @Test("oversized text alongside an image renders the image preview")
    func oversizedTextWithImage() {
        let big = String(repeating: "a", count: ClipboardPreviewPolicy.maxEditableTextBytes + 1)
        let content = ClipboardContent(representations: [
            .init(uti: ClipboardContent.utf8TextUTI, data: Data(big.utf8)),
            .init(uti: UTType.png.identifier, data: Data([0x89])),
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .image(data: Data([0x89]), uti: UTType.png.identifier))
    }

    @Test("unknown representations render the summary")
    func unknownRepsSummary() {
        let content = ClipboardContent(representations: [
            .init(uti: "com.example.custom-blob", data: Data([1, 2, 3]))
        ])
        #expect(ClipboardPreviewPolicy.mode(for: content) == .summary(content.representations))
    }
}
