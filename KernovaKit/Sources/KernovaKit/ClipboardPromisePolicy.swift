import Foundation
import KernovaWire

/// The receive-side gate on the items a peer offered: which representations
/// may be published and pulled at all, which pasteboard type each serves, and
/// the deadline-bound total the paste cap is compared against.
///
/// Every rule here reads offer metadata only — no byte of the offer has crossed
/// when they are applied.
public enum ClipboardPromisePolicy {
    /// Whether an offered representation is kept: published to the pasteboard,
    /// and reachable by a pull.
    ///
    /// An INLINE representation is kept when it names a type a Mac pasteboard
    /// carries that is not an identity-skip type (a marker, a file reference).
    /// Its size is not consulted: a sender reads no bytes to offer, so an
    /// estimate of 0 means unknown. A FILE or FOLDER is always kept: the offer
    /// registry admits no item whose name breaks `Representation.name`'s
    /// contract.
    public static func keeps(_ representation: Representation) -> Bool {
        switch representation.storage {
        case .inline:
            guard let uti = representation.type.appleUTI else { return false }
            return !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: uti)
        case .file, .folder:
            return true
        case .unspecified, .UNRECOGNIZED:
            return false
        }
    }

    /// Whether a kept representation is served as `public.file-url` — the
    /// flavor whose bytes must pull and land inside the OS pasteboard-promise
    /// deadline.
    public static func servesFileURL(_ representation: Representation) -> Bool {
        keeps(representation) && representation.storage != .inline
    }

    /// One pasteboard type a published item promises, and the representation
    /// that serves it.
    public struct PromisedType: Equatable, Sendable {
        /// The pasteboard type: the representation's UTI, or `public.file-url`.
        public let pasteboardType: String
        /// Index into the item's representations.
        public let representation: Int

        /// Whether the type is `public.file-url`, served by landing a FILE or
        /// FOLDER and handing over its URL.
        public var isFileURL: Bool { pasteboardType == ClipboardPasteboardPublisher.ItemSpec.fileURLType }
    }

    /// The pasteboard types `item` promises, in its order of preference.
    ///
    /// Each type is served by the first kept representation that maps to it, so
    /// an item's best representation of a type wins. `servingFileURLs` false
    /// withholds `public.file-url`, leaving the item's inline types.
    public static func promisedTypes(for item: OfferedItem, servingFileURLs: Bool = true) -> [PromisedType] {
        var types: [PromisedType] = []
        var seen: Set<String> = []
        for (index, representation) in item.representations.enumerated() where keeps(representation) {
            let pasteboardType: String
            if representation.storage == .inline, let uti = representation.type.appleUTI {
                pasteboardType = uti
            } else if servingFileURLs {
                pasteboardType = ClipboardPasteboardPublisher.ItemSpec.fileURLType
            } else {
                continue
            }
            if seen.insert(pasteboardType).inserted {
                types.append(PromisedType(pasteboardType: pasteboardType, representation: index))
            }
        }
        return types
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

    /// The paste-bound total of `items` against `limit`: the size estimate of
    /// every representation served as `public.file-url`, which is the payload
    /// one paste has to land against the OS deadline.
    ///
    /// One paste is one deadline-bound operation, so the OS clock sees the sum
    /// rather than each file: a set over the cap is refused whole rather than
    /// landing 2 of 3 files. A promised representation counts its estimate, 0
    /// while its size is unknown. The sum saturates, so an absurd declared total
    /// fails the cap rather than wrapping under it.
    public static func pasteBudget(_ items: [OfferedItem], limit: Int) -> PasteBudget {
        var total: UInt64 = 0
        for item in items {
            for promised in promisedTypes(for: item) where promised.isFileURL {
                total = total.saturatingAdding(item.representations[promised.representation].sizeEstimate)
            }
        }
        return PasteBudget(total: total, limit: limit)
    }

    /// How a copy is written within the paste ceiling, decided before anything of it is written.
    public enum CopyPlan: Equatable, Sendable {
        /// Whole: its files fit.
        case whole
        /// Without its `files` file representations, which do not fit; the rest is written.
        case withoutFiles(count: Int)
        /// Not at all: its files do not fit, and nothing else is in it.
        case tooLarge

        /// Whether the write serves `public.file-url`.
        public var servesFileURLs: Bool { self == .whole }
    }

    /// How `items` are written as a copy whose files may land at most `room` bytes more: what is left of the
    /// copy's budget once its INLINE representations landed.
    public static func copyPlan(_ items: [OfferedItem], room: UInt64) -> CopyPlan {
        let files = fileCount(items)
        guard files > 0, pasteBudget(items, limit: Int(clamping: room)).exceeds else { return .whole }
        let remains = items.contains { !promisedTypes(for: $0, servingFileURLs: false).isEmpty }
        return remains ? .withoutFiles(count: files) : .tooLarge
    }

    /// How many representations of `items` are served as `public.file-url`.
    public static func fileCount(_ items: [OfferedItem]) -> Int {
        items.reduce(0) { $0 + promisedTypes(for: $1).filter(\.isFileURL).count }
    }
}
