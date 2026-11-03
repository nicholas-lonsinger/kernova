import Foundation
import KernovaWire
import UniformTypeIdentifiers

extension ClipboardContent {
    /// The metadata of a peer's offered `items`, for display before any byte
    /// is pulled: every representation pending remote.
    ///
    /// An item with a kept FILE or FOLDER shows as that one file or folder,
    /// its INLINE forms being the same content; any other item shows each kept
    /// INLINE representation.
    public init(previewOf items: [OfferedItem], concealed: Bool) {
        var representations: [Representation] = []
        for item in items {
            let kept = item.representations.filter(ClipboardPromisePolicy.keeps)
            if let file = kept.first(where: { $0.storage != .inline }) {
                representations.append(
                    Representation(
                        pendingRemoteUTI: file.type.appleUTI
                            ?? (file.storage == .folder ? UTType.folder : UTType.data).identifier,
                        byteCount: Self.byteCount(file.sizeEstimate),
                        filename: String(decoding: file.name, as: UTF8.self),
                        isDirectory: file.storage == .folder))
                continue
            }
            for inline in kept {
                guard let uti = inline.type.appleUTI else { continue }
                representations.append(
                    Representation(pendingRemoteUTI: uti, byteCount: Self.byteCount(inline.sizeEstimate)))
            }
        }
        self.init(representations: representations, isConcealed: concealed)
    }

    private static func byteCount(_ estimate: UInt64) -> Int {
        Int(clamping: estimate)
    }
}
