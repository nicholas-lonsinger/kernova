import Foundation
import KernovaProtocol
import UniformTypeIdentifiers

extension UTType {
    /// RTF-family rich-text flavors, richest first.
    ///
    /// flat-RTFD (`com.apple.flat-rtfd`) carries inline images and styling; plain
    /// RTF (`public.rtf`) is text-only and cannot embed raster images. A rich-text
    /// copy with an embedded image advertises *both*, so the image survives only
    /// if flat-RTFD is preferred — hence the order. flat-RTFD does **not** conform
    /// to `.rtf`, so a bare `conforms(to: .rtf)` check misses the image-bearing
    /// flavor. The bundle form `com.apple.rtfd` (`UTType.rtfd`) is intentionally
    /// absent: it never appears as an inline pasteboard flavor — the flat form
    /// does — and as a directory bundle its bytes aren't decodable like a flat
    /// stream, so modeling it would be speculative.
    static let rtfFamilyByPreference: [UTType] = [.flatRTFD, .rtf]

    /// Whether this type is any RTF-family rich-text flavor (see
    /// `rtfFamilyByPreference`).
    var conformsToRTFFamily: Bool {
        UTType.rtfFamilyByPreference.contains { conforms(to: $0) }
    }

    /// Whether bytes of this type must be decoded with the RTFD document type —
    /// flat-RTFD carries attachments, so it needs `.rtfd`, not `.rtf`.
    var needsRTFDDocumentType: Bool {
        conforms(to: .flatRTFD)
    }
}

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
}

extension ClipboardContent {
    /// Every file payload — each a representation tagged with a suggested
    /// filename (a copied/dragged file's bytes).
    ///
    /// Partitions the buffer with `inlineRepresentations`: a non-empty filename
    /// marks a distinct file the receiver materializes, so several of these mean
    /// several files. `filePayloads.first` is the single-file representative.
    var filePayloads: [Representation] {
        representations.filter { !$0.filename.isEmpty }
    }

    /// The inline representations — alternative encodings of one inline content
    /// item (text + RTF + image data; the consumer picks the richest).
    ///
    /// The complement of `filePayloads`.
    var inlineRepresentations: [Representation] {
        representations.filter { $0.filename.isEmpty }
    }

    /// The inline rich-text representation best suited to a styled preview, or
    /// `nil` when none is present.
    ///
    /// Prefers the richest RTF-family flavor (flat-RTFD over plain RTF) so a copy
    /// with an embedded inline image previews *with* the image — the image bytes
    /// live only in the flat-RTFD flavor, never in plain RTF. File payloads are
    /// excluded — a copied `.rtf`/`.rtfd` *file* is a file attachment, not inline
    /// rich text. HTML is deliberately *not* rendered styled: `NSAttributedString`'s
    /// HTML import can synchronously fetch remote resources and block the main
    /// thread, which is unsafe for untrusted clipboard bytes — HTML copies fall
    /// through to the plain-text preview instead.
    var richTextRepresentation: Representation? {
        // Single pass: parse each inline rep's UTType once and keep the one with
        // the best (lowest-index) `rtfFamilyByPreference` rank.
        var best: (rank: Int, rep: Representation)?
        for representation in representations where representation.filename.isEmpty {
            guard let type = UTType(representation.uti),
                let rank = UTType.rtfFamilyByPreference.firstIndex(where: { type.conforms(to: $0) })
            else { continue }
            if let best, best.rank <= rank { continue }
            best = (rank, representation)
        }
        return best?.rep
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
