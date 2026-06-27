import Foundation

/// The minimal facts about one offered representation that the pasteboard-item
/// grouping decision needs.
///
/// Both sides of the clipboard bridge build these from their own source — the
/// host from a `ClipboardContent.Representation` (`isInline` =
/// `shouldInlineOnPasteboard`, every rep `isPromisable`), the guest agent from a
/// wire `ClipboardRepresentationInfo` (`isInline` = the offered bit,
/// `isPromisable` = the receive-side sanitization gate) — then hand the list to
/// `ClipboardPasteboardItemPlan.plan(for:)`. Keeping the grouping free of any
/// `ClipboardContent` / protobuf / AppKit type makes it pure, `Sendable`, and
/// directly testable.
public struct ClipboardRepresentationDescriptor: Equatable, Sendable {
    /// Uniform Type Identifier naming the representation's format.
    public let uti: String

    /// Suggested filename — empty for inline-only content, non-empty for a file
    /// payload.
    public let filename: String

    /// Whether the representation inlines onto the pasteboard (vs. file-only),
    /// per `ClipboardContent.Representation.shouldInlineOnPasteboard`.
    public let isInline: Bool

    /// Whether the representation may be promised at all — the host admits every
    /// rep; the guest drops empty reps and identity-skip smuggles before they can
    /// be pulled.
    public let isPromisable: Bool

    /// Creates a descriptor from the four grouping inputs.
    public init(uti: String, filename: String, isInline: Bool, isPromisable: Bool) {
        self.uti = uti
        self.filename = filename
        self.isInline = isInline
        self.isPromisable = isPromisable
    }
}

/// The pasteboard items to promise for one clipboard offer — the grouping
/// decision shared by the host "Copy to Mac" path and the guest inbound-paste
/// path, expressed purely in terms of representation indices.
///
/// A single inline item promises every inline (filename-less) representation;
/// each file payload becomes its own item promising exactly one `.fileURL` (and,
/// for an image file, its inline image bytes too). One `.fileURL` per item is
/// what a Finder paste needs to create N files — a single item holds only one
/// value per type, so several file URLs in one item would collide. Each promised
/// type carries the index of the representation that backs it, so a caller maps
/// an index to its own byte source (the host stages a file / serves resident
/// bytes; the guest streams the bytes over vsock on demand).
public struct ClipboardPasteboardItemPlan: Equatable, Sendable {
    /// One promised pasteboard type within an item, tagged with the index of the
    /// representation that backs it.
    ///
    /// `isFileURL` marks the `public.file-url` promise of a file payload (the
    /// caller substitutes `.fileURL` for `uti` when realizing the item); a
    /// `false` value promises the representation's content `uti` directly.
    public struct PromisedType: Equatable, Sendable {
        /// The content UTI to promise — ignored by the caller when `isFileURL`.
        public let uti: String

        /// Index into the input descriptor list of the representation that backs
        /// this type.
        public let representationIndex: Int

        /// Whether this promises `public.file-url` rather than the content UTI.
        public let isFileURL: Bool

        /// Creates a promised type tagged with its backing representation index.
        public init(uti: String, representationIndex: Int, isFileURL: Bool) {
            self.uti = uti
            self.representationIndex = representationIndex
            self.isFileURL = isFileURL
        }
    }

    /// One pasteboard item: the ordered types it promises.
    public struct Item: Equatable, Sendable {
        /// The promised types, in offer order.
        public let types: [PromisedType]

        /// Creates an item from its ordered promised types.
        public init(types: [PromisedType]) {
            self.types = types
        }
    }

    /// The promised items, the shared inline item (when any) first.
    public let items: [Item]

    /// Creates a plan from its ordered items.
    public init(items: [Item]) {
        self.items = items
    }

    /// Groups offered representations into the pasteboard items to promise.
    ///
    /// One shared inline item collects every promisable, filename-less, inline
    /// representation, deduped by UTI with the first (richest, since offers are
    /// richest-first) winning and offer order preserved. Each promisable file
    /// payload then becomes its own item — its image UTI first when it inlines,
    /// then `.fileURL`. Non-promisable representations are skipped in place, so
    /// every surviving `representationIndex` still indexes the *input* list (a
    /// caller resolves a requested type to the correct backing representation).
    public static func plan(
        for reps: [ClipboardRepresentationDescriptor]
    ) -> ClipboardPasteboardItemPlan {
        var items: [Item] = []

        // One shared inline item for all inline-only (filename-less) reps.
        var inlineTypes: [PromisedType] = []
        var seenUTIs: Set<String> = []
        for (index, rep) in reps.enumerated()
        where rep.isPromisable && rep.filename.isEmpty && rep.isInline {
            if seenUTIs.insert(rep.uti).inserted {
                inlineTypes.append(
                    PromisedType(uti: rep.uti, representationIndex: index, isFileURL: false))
            }
        }
        if !inlineTypes.isEmpty { items.append(Item(types: inlineTypes)) }

        // One item per file payload (image files also promise their image UTI).
        for (index, rep) in reps.enumerated()
        where rep.isPromisable && !rep.filename.isEmpty {
            var types: [PromisedType] = []
            if rep.isInline {
                types.append(
                    PromisedType(uti: rep.uti, representationIndex: index, isFileURL: false))
            }
            types.append(PromisedType(uti: rep.uti, representationIndex: index, isFileURL: true))
            items.append(Item(types: types))
        }

        return ClipboardPasteboardItemPlan(items: items)
    }
}
