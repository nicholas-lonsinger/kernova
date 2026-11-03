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

/// The promise gate over the clipboard ports' offer metadata, which
/// ``ClipboardPromisePolicy`` states over the item model.
extension ClipboardPromisePolicy {
    /// Whether an offered representation is kept: surfaced to the pasteboard,
    /// and reachable by a pull.
    ///
    /// An identity-skip type (a transient marker, a raw `public.file-url`
    /// smuggle) or an inline payload with no bytes is never kept.
    ///
    /// The empty-payload skip is keyed on the *filename*, so it reaches only
    /// inline reps. A named rep is a file the paste creates, and an empty file
    /// is content native macOS copies; a folder's `byte_count` is an estimate of
    /// the tree's file bytes (`kernova.proto`), which a tree of empty files, bare
    /// subdirectories, or nothing at all makes 0 while the archive still carries
    /// the tree.
    public static func keeps(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        (info.byteCount != 0 || !info.filename.isEmpty)
            && !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: info.uti)
    }

    /// Whether a promised item serves this representation as `public.file-url`.
    ///
    /// `ClipboardPasteboardItemPlan` promises `.fileURL` for every kept rep
    /// carrying a filename, so an image file — which also promises its image UTI
    /// inline — is one of them.
    public static func servesFileURL(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        keeps(info) && !info.filename.isEmpty
    }

    /// The paste-bound total of `reps` against `limit`: the byte count of every
    /// representation served as `public.file-url`. The sum saturates.
    public static func pasteBudget(
        _ reps: [Kernova_V1_ClipboardRepresentationInfo], limit: Int
    ) -> PasteBudget {
        var total: UInt64 = 0
        for info in reps where servesFileURL(info) {
            total = total.saturatingAdding(info.byteCount)
        }
        return PasteBudget(total: total, limit: limit)
    }

    /// The pasteboard-item grouping inputs for `reps`, each tagged with whether
    /// this gate keeps it.
    public static func descriptors(
        for reps: [Kernova_V1_ClipboardRepresentationInfo]
    ) -> [ClipboardRepresentationDescriptor] {
        reps.map {
            ClipboardRepresentationDescriptor(
                uti: $0.uti, filename: $0.filename, isInline: $0.isInline,
                isPromisable: keeps($0))
        }
    }
}
