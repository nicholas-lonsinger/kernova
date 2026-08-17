import Foundation

/// The receive-side gate on the representations a peer offered: which may be
/// promised and pulled at all, which of those a paste serves as
/// `public.file-url`, and the deadline-bound total the paste cap is compared
/// against.
///
/// Every rule here reads offer metadata only — no byte of the offer has crossed
/// when they are applied.
public enum ClipboardPromisePolicy {
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

    /// Whether a promised item serves this representation as `public.file-url` —
    /// the flavor whose bytes must pull, stage, and (for a folder) extract
    /// inside the OS pasteboard-promise deadline.
    ///
    /// `ClipboardPasteboardItemPlan` promises `.fileURL` for every kept rep
    /// carrying a filename, so an image file — which also promises its image UTI
    /// inline — is one of them.
    public static func servesFileURL(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        keeps(info) && !info.filename.isEmpty
    }

    /// An offer's paste-bound total against the ceiling in force.
    public struct PasteBudget: Equatable, Sendable {
        /// Total declared bytes of every representation served as
        /// `public.file-url`.
        public let total: UInt64
        /// The ceiling this total was measured against.
        public let limit: Int
        /// Whether the set is over the ceiling, and so refused whole. A total
        /// exactly at the cap is within it.
        public var exceeds: Bool { total > UInt64(limit) }
    }

    /// The paste-bound total of `reps` against `limit`: the byte count of every
    /// representation served as `public.file-url`, which is the payload one
    /// paste has to land against the OS deadline.
    ///
    /// One paste is one deadline-bound operation, so the OS clock sees the sum
    /// rather than each file: a set over the cap is refused whole rather than
    /// landing 2 of 3 files. A directory rep contributes the producer's
    /// stat-walk estimate, the same figure the wire carries as its `byte_count`.
    /// The sum saturates, so an absurd declared total fails the cap rather than
    /// wrapping under it.
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
