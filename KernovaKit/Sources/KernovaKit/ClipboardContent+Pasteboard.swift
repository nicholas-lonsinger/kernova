import Foundation
import UniformTypeIdentifiers

extension ClipboardContent.Representation {
    /// Whether this representation's bytes should be written inline to a
    /// pasteboard, rather than carried only as a materialized file URL.
    ///
    /// Non-file content (no filename) and image file payloads inline so the
    /// receiver (Notes/TextEdit) shows them in place; every other file payload
    /// is file-only so it attaches as a file rather than inserting its contents.
    /// A directory is always file-only — its bytes are an archive of the tree,
    /// never something to insert inline. Both sides of the clipboard bridge apply
    /// this single rule: the host writes its "Copy to Mac" pasteboard items from
    /// it, and the guest agent both promises inbound items and tags each offered
    /// representation's `isInline` wire bit with it.
    public var shouldInlineOnPasteboard: Bool {
        if isDirectory { return false }
        if filename.isEmpty { return true }
        return UTType(uti)?.conforms(to: .image) == true
    }
}
