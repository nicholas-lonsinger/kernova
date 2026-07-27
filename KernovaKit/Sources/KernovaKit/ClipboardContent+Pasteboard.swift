import Foundation
import UniformTypeIdentifiers

extension ClipboardContent.Representation {
    /// Whether this representation's bytes should be written inline to a
    /// pasteboard, rather than carried only as a materialized file URL.
    ///
    /// Inlining makes the receiver (Notes/TextEdit) show the payload in place
    /// rather than attaching it as a file.
    public var shouldInlineOnPasteboard: Bool {
        if isDirectory { return false }
        if filename.isEmpty { return true }
        return UTType(uti)?.conforms(to: .image) == true
    }
}
