import Foundation

extension ClipboardContent.Representation {
    /// The wire metadata advertised for this representation in a `ClipboardOffer`.
    ///
    /// Both ends of the clipboard bridge build the same offer entry: the host
    /// "Copy to Mac" path and the guest inbound-offer path each map their capped
    /// `representations` through this to populate `ClipboardOffer.repInfo`.
    /// `isInline` reuses the shared `shouldInlineOnPasteboard` rule, so the
    /// offered bit and the pasteboard-write decision can never diverge.
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
