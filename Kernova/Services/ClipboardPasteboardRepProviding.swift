import Foundation

/// Implemented by a clipboard service so the host pasteboard publisher can serve
/// a promised representation's bytes inside the paste callback.
protocol ClipboardPasteboardRepProviding: AnyObject, Sendable {
    /// Resolves the pasteboard `.fileURL` for a promised rep at paste time, or
    /// `nil` when nothing can be served.
    ///
    /// Serves the materialization cache when the rep was already pulled, else
    /// runs a deadline-bound blocking pull gated all-or-nothing by the offer's
    /// paste-bound byte total. Safe to call on the main thread even though it
    /// blocks.
    func copyToMacFileURL(generation: UInt64, repIndex: Int) -> URL?

    /// Resolves an inline pasteboard flavor's bytes for a promised rep at paste
    /// time, or `nil` when nothing can be served.
    ///
    /// Serves the materialization cache when the rep was already pulled (a
    /// preview, or the item's sibling flavor), else runs a blocking pull. Safe to
    /// call on the main thread even though it blocks.
    func copyToMacData(generation: UInt64, repIndex: Int, uti: String) -> Data?
}
