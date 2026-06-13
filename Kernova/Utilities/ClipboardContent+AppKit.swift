import Foundation
import KernovaProtocol
import UniformTypeIdentifiers

extension ClipboardContent {
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
}
