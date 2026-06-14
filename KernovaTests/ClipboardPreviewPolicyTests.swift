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

    @Test("an image alongside a URL/path descriptor shows the image, not the URL")
    func imageBeatsURLDescriptor() {
        // A dragged image whose pasteboard also carried its http(s) URL (e.g.
        // a Safari image) — the image must win over the descriptor text.
        let pngData = Data([0x89, 0x50])
        let content = ClipboardContent(representations: [
            .init(uti: UTType.png.identifier, data: pngData),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("https://example.com/cat.png".utf8)),
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .image(data: pngData, uti: UTType.png.identifier))
    }

    @Test("an image alongside a standalone public.url rep shows the image")
    func imageBeatsStandaloneURLRep() {
        let pngData = Data([0x89, 0x50])
        let content = ClipboardContent(representations: [
            .init(uti: UTType.png.identifier, data: pngData),
            .init(uti: "public.url", data: Data("https://example.com/cat.png".utf8)),
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .image(data: pngData, uti: UTType.png.identifier))
    }

    @Test("an image alongside genuine prose still shows the text")
    func proseBeatsImage() {
        // The descriptor guard must NOT fire for real text: a caption is prose,
        // not a path/URL, so text-wins still holds (RTF+plain-text behavior).
        let content = ClipboardContent(representations: [
            .init(uti: UTType.png.identifier, data: Data([0x89])),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("Here is a caption for the photo".utf8)),
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .text("Here is a caption for the photo"))
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
