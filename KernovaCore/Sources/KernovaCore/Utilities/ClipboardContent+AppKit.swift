import Foundation
import KernovaKit
import UniformTypeIdentifiers

extension UTType {
    /// RTF-family rich-text flavors, richest first.
    ///
    /// flat-RTFD (`com.apple.flat-rtfd`) carries inline images and styling; plain
    /// RTF (`public.rtf`) is text-only and cannot embed raster images. A rich-text
    /// copy with an embedded image advertises *both*, so the image survives only
    /// if flat-RTFD is preferred — hence the order. flat-RTFD does **not** conform
    /// to `.rtf`, so a bare `conforms(to: .rtf)` check misses the image-bearing
    /// flavor.
    static let rtfFamilyByPreference: [UTType] = [.flatRTFD, .rtf]

    /// Whether this type is any RTF-family rich-text flavor.
    var conformsToRTFFamily: Bool {
        UTType.rtfFamilyByPreference.contains { conforms(to: $0) }
    }

    /// Whether bytes of this type must be decoded with the RTFD document type —
    /// flat-RTFD carries attachments, so it needs `.rtfd`, not `.rtf`.
    package var needsRTFDDocumentType: Bool {
        conforms(to: .flatRTFD)
    }
}

extension ClipboardContent {
    /// Every file payload — each a representation tagged with a suggested
    /// filename (a copied/dragged file's bytes).
    ///
    /// A non-empty filename marks a distinct file the receiver materializes, so
    /// several of these mean several files.
    package var filePayloads: [Representation] {
        representations.filter { !$0.filename.isEmpty }
    }

    /// The inline rich-text representation best suited to a styled preview, or
    /// `nil` when none is present.
    ///
    /// Prefers the richest RTF-family flavor so a copy with an embedded inline
    /// image previews *with* the image. HTML is *not* rendered styled:
    /// `NSAttributedString`'s HTML import can synchronously fetch remote
    /// resources and block the main thread, which is unsafe for untrusted
    /// clipboard bytes.
    var richTextRepresentation: Representation? {
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
}
