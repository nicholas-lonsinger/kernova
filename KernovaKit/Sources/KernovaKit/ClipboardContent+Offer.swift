import Foundation

extension ClipboardContent.Representation {
    /// The wire metadata advertised for this representation in a `ClipboardOffer`.
    public var offerRepresentationInfo: Kernova_V1_ClipboardRepresentationInfo {
        Kernova_V1_ClipboardRepresentationInfo.with {
            $0.uti = uti
            $0.byteCount = UInt64(byteCount)
            $0.filename = filename
            $0.isInline = shouldInlineOnPasteboard
            $0.isDirectory = isDirectory
        }
    }
}
