import Foundation
import KernovaKit
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

    @Test("concealed content short-circuits to the placeholder regardless of type")
    func concealedShortCircuits() {
        // Even ordinary plain text, if marked concealed, must never reach the
        // editable text editor — it renders as the placeholder.
        let content = ClipboardContent(
            representations: [.init(uti: ClipboardContent.utf8TextUTI, data: Data("hunter2".utf8))],
            isConcealed: true)
        #expect(ClipboardPreviewPolicy.mode(for: content) == .concealed)
    }

    @Test("inline rich text renders styled instead of plain")
    func richTextWinsOverPlain() {
        // A TextEdit rich copy carries RTF + a plain-text sibling; the styled
        // RTF should be shown, not the flattened plain text.
        let rtf = Data("{\\rtf1}".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.rtf.identifier, data: rtf),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .richText(data: rtf, uti: UTType.rtf.identifier))
    }

    @Test("flat-RTFD wins over plain RTF for the rich preview")
    func flatRTFDBeatsPlainRTFForRichPreview() {
        // A TextEdit copy of styled text with an inline image advertises, in
        // order: flat-RTFD (carries the image), plain RTF (text-only), then a
        // plain-text sibling. The image-bearing flat-RTFD must be previewed —
        // it does not conform to `.rtf`, so the policy must prefer it explicitly.
        let rtfd = Data("rtfd-with-image".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.flatRTFD.identifier, data: rtfd),
            .init(uti: UTType.rtf.identifier, data: Data("{\\rtf1}".utf8)),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .richText(data: rtfd, uti: UTType.flatRTFD.identifier))
    }

    @Test("flat-RTFD alone renders the rich preview")
    func flatRTFDOnlyRendersRich() {
        // Even without a sibling plain RTF, flat-RTFD is rich text (not a plain
        // image and not `.rtf`-conforming) and must render styled, not as a
        // summary or the plain-text editor.
        let rtfd = Data("rtfd-with-image".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.flatRTFD.identifier, data: rtfd),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .richText(data: rtfd, uti: UTType.flatRTFD.identifier))
    }

    @Test("a flat-RTFD rep beats a coexisting bare image rep (the RTFD carries the image)")
    func flatRTFDBeatsBareImageSibling() {
        // Some apps vend a styled snippet as flat-RTFD *and* a standalone image
        // flavor on the same item. The RTFD must win so the preview renders the
        // styled text with its inline image, not just the bare image — the
        // richText branch precedes the bare-image branch in mode(for:).
        let rtfd = Data("rtfd-with-image".utf8)
        let png = Data([0x89, 0x50])
        let content = ClipboardContent(representations: [
            .init(uti: UTType.flatRTFD.identifier, data: rtfd),
            .init(uti: UTType.png.identifier, data: png),
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .richText(data: rtfd, uti: UTType.flatRTFD.identifier))
    }

    @Test("a copied .rtfd file attaches as a file, not inline rich text")
    func rtfdFilePayloadShowsChip() {
        // The file-payload rule must beat the rich-text rule for RTFD too: a
        // copied .rtfd *file* is a file attachment, not styled inline content.
        let rtfd = Data("rtfd-bytes".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.flatRTFD.identifier, data: rtfd, filename: "styled.rtfd")
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .file(filename: "styled.rtfd", uti: UTType.flatRTFD.identifier, byteCount: rtfd.count))
    }

    @Test("a non-image file payload renders the file chip")
    func nonImageFilePayloadShowsChip() {
        let bytes = Data("hello".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: bytes, filename: "note.txt")
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .file(filename: "note.txt", uti: UTType.plainText.identifier, byteCount: bytes.count))
    }

    @Test("several file payloads render the multi-file list, in order")
    func multipleFilePayloadsShowFilesList() {
        // A mix of file types (image and not) still renders as the file list
        // whenever there is more than one file payload.
        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("a".utf8), filename: "a.txt"),
            .init(uti: UTType.png.identifier, data: Data([0x89]), filename: "b.png"),
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .files([
                    .init(filename: "a.txt", uti: UTType.plainText.identifier, byteCount: 1),
                    .init(filename: "b.png", uti: UTType.png.identifier, byteCount: 1),
                ]))
    }

    @Test("a single file payload still renders the single-file chip, not the list")
    func singleFilePayloadShowsChipNotList() {
        let content = ClipboardContent(representations: [
            .init(uti: UTType.plainText.identifier, data: Data("a".utf8), filename: "a.txt")
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .file(filename: "a.txt", uti: UTType.plainText.identifier, byteCount: 1))
    }

    @Test("an image file payload still renders the image preview")
    func imageFilePayloadShowsImage() {
        let png = Data([0x89, 0x50])
        let content = ClipboardContent(representations: [
            .init(uti: UTType.png.identifier, data: png, filename: "photo.png")
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .image(data: png, uti: UTType.png.identifier))
    }

    @Test("a file-backed image payload renders the image-file preview")
    func fileBackedImagePayloadShowsImageFile() {
        // A copied image *file* (or a streamed/materialized guest image file)
        // has its bytes on disk, not resident — it must still preview as an
        // image (decoded from the URL), matching an inline image rather than
        // degrading to a file chip.
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        let content = ClipboardContent(representations: [
            .init(uti: UTType.png.identifier, fileURL: url, byteCount: 4096, filename: "photo.png")
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .imageFile(url: url, uti: UTType.png.identifier))
    }

    @Test("a file-backed non-image payload renders the file chip")
    func fileBackedNonImagePayloadShowsChip() {
        let url = URL(fileURLWithPath: "/tmp/archive.zip")
        let content = ClipboardContent(representations: [
            .init(uti: UTType.zip.identifier, fileURL: url, byteCount: 1024, filename: "archive.zip")
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .file(filename: "archive.zip", uti: UTType.zip.identifier, byteCount: 1024))
    }

    @Test("a copied .rtf file attaches as a file, not inline rich text")
    func rtfFilePayloadShowsChip() {
        // The file-payload rule must beat the rich-text rule: a copied .rtf
        // file is a file attachment, not styled inline content.
        let rtf = Data("{\\rtf1}".utf8)
        let content = ClipboardContent(representations: [
            .init(uti: UTType.rtf.identifier, data: rtf, filename: "styled.rtf")
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .file(filename: "styled.rtf", uti: UTType.rtf.identifier, byteCount: rtf.count))
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

    // MARK: - Lazy-receive placeholders (.pendingRemote)

    @Test("a .pendingRemote image rep with a filename renders the file chip, not an image")
    func pendingRemoteImageWithFilenameShowsChip() {
        // A not-yet-pulled image *file* offer has no resident bytes, so the
        // window must render a chip (filename · type · size) rather than try to
        // decode an image from absent data.
        let content = ClipboardContent(representations: [
            .init(pendingRemoteUTI: UTType.png.identifier, byteCount: 4096, filename: "photo.png")
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .file(filename: "photo.png", uti: UTType.png.identifier, byteCount: 4096))
    }

    @Test("a .pendingRemote inline rep with no filename renders the summary")
    func pendingRemoteInlineNoFilenameShowsSummary() {
        // A placeholder for an inline rep (e.g. an over-limit image not eagerly
        // pulled, or text awaiting Copy-to-Mac) has no bytes to preview and no
        // filename to chip, so it falls through to the per-rep summary.
        let content = ClipboardContent(representations: [
            .init(pendingRemoteUTI: UTType.png.identifier, byteCount: 64 * 1024 * 1024)
        ])
        #expect(ClipboardPreviewPolicy.mode(for: content) == .summary(content.representations))
    }

    @Test("a materialized .inMemory image rep renders the image preview")
    func materializedInlineImageShowsImage() {
        // The counterpart to the placeholder cases: once the image rep is pulled
        // into memory, the same policy renders it richly.
        let png = Data([0x89, 0x50])
        let content = ClipboardContent(representations: [
            .init(uti: UTType.png.identifier, data: png)
        ])
        #expect(
            ClipboardPreviewPolicy.mode(for: content)
                == .image(data: png, uti: UTType.png.identifier))
    }
}
