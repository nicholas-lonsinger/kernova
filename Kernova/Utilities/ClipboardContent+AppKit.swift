import Foundation
import KernovaProtocol
import UniformTypeIdentifiers

extension ClipboardContent.Representation {
    /// Whether this representation's bytes should be written inline to a
    /// pasteboard, rather than carried only as a materialized file URL.
    ///
    /// Non-file content (no filename) and image file payloads inline so the
    /// receiver (Notes/TextEdit) shows them in place; every other file payload
    /// is file-only so it attaches as a file rather than inserting its
    /// contents. Mirrors `VsockGuestClipboardAgent.shouldInline(_:)`, which
    /// applies the same rule on the guest side (a separate target can't share
    /// this extension).
    var shouldInlineOnPasteboard: Bool {
        if filename.isEmpty { return true }
        return UTType(uti)?.conforms(to: .image) == true
    }

    /// Whether this representation conforms to `public.image`.
    var isImage: Bool {
        UTType(uti)?.conforms(to: .image) == true
    }
}

extension ClipboardContent {
    /// The single file payload in the buffer, if any — a representation tagged
    /// with a suggested filename (a copied/dragged file's bytes).
    ///
    /// The buffer models one logical pasteboard item, so a file copy/drop
    /// produces exactly one filename-tagged representation.
    var filePayload: Representation? {
        representations.first { !$0.filename.isEmpty }
    }

    /// The inline RTF representation best suited to a styled preview, or `nil`
    /// when none is present.
    ///
    /// File payloads are excluded — a copied `.rtf` *file* is a file
    /// attachment, not inline rich text. HTML is deliberately *not* rendered
    /// styled: `NSAttributedString`'s HTML import can synchronously fetch
    /// remote resources and block the main thread, which is unsafe for
    /// untrusted clipboard bytes — HTML copies fall through to the plain-text
    /// preview instead.
    var richTextRepresentation: Representation? {
        representations.first { $0.filename.isEmpty && UTType($0.uti)?.conforms(to: .rtf) == true }
    }

    /// The representation best suited to an image preview, or `nil` when
    /// none of the representations is an image.
    ///
    /// Preference order: PNG, TIFF, JPEG, HEIC, then anything whose UTI
    /// conforms to `public.image` — the well-known formats decode reliably
    /// and cheaply; the conformance fallback catches the long tail.
    var imageRepresentation: Representation? {
        let preferred = [
            UTType.png.identifier,
            UTType.tiff.identifier,
            UTType.jpeg.identifier,
            UTType.heic.identifier,
        ]
        for identifier in preferred {
            if let representation = representations.first(where: { $0.uti == identifier }) {
                return representation
            }
        }
        return representations.first { representation in
            UTType(representation.uti)?.conforms(to: .image) == true
        }
    }

    /// `true` when an image representation is present and the only textual
    /// representations are file paths or URLs — i.e. a *descriptor* of the
    /// image, not real text content.
    ///
    /// The preview policy uses this so a dragged/copied image whose pasteboard
    /// also carried its path/URL string shows the **image**, not the path —
    /// while a genuine text copy (prose, even if it mentions a URL) still
    /// shows as text.
    var textIsPathOrURLOnly: Bool {
        guard imageRepresentation != nil else { return false }
        // A standalone URL representation alongside an image is a descriptor.
        let urlUTIs: Set<String> = ["public.url", "public.file-url", "Apple URL pasteboard type"]
        let hasURLRep = representations.contains { urlUTIs.contains($0.uti) }
        guard let text else { return hasURLRep }
        return Self.looksLikePathOrURL(text)
    }

    /// Whether a string is a single-line `file://`/`http://`/`https://` URL.
    ///
    /// Strict by design: multi-line text or a non-URL string is treated as
    /// prose (returns false) so real captions never trigger the
    /// image-beats-text rule.
    private static func looksLikePathOrURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return ["file", "http", "https"].contains(scheme)
    }
}
