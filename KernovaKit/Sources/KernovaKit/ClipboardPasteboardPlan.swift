import Foundation

/// The minimal facts about one offered representation that the pasteboard-item
/// grouping decision needs.
public struct ClipboardRepresentationDescriptor: Equatable, Sendable {
    /// Uniform Type Identifier naming the representation's format.
    public let uti: String

    /// Suggested filename — empty for inline-only content, non-empty for a file
    /// payload.
    public let filename: String

    /// Whether the representation inlines onto the pasteboard (vs. file-only),
    /// per `ClipboardContent.Representation.shouldInlineOnPasteboard`.
    public let isInline: Bool

    /// Whether the representation may be promised at all.
    public let isPromisable: Bool

    /// Creates a descriptor from the four grouping inputs.
    public init(uti: String, filename: String, isInline: Bool, isPromisable: Bool) {
        self.uti = uti
        self.filename = filename
        self.isInline = isInline
        self.isPromisable = isPromisable
    }
}

/// The pasteboard items to promise for one clipboard offer, expressed purely in
/// terms of representation indices.
///
/// Each file payload gets its own item promising exactly one `.fileURL`: that is
/// what a Finder paste needs to create N files, since an item holds only one
/// value per type and several file URLs in one item would collide. A promised
/// type carries the index of the representation backing it, so a caller can map
/// an index to its own byte source.
public struct ClipboardPasteboardItemPlan: Equatable, Sendable {
    /// One promised pasteboard type within an item, tagged with the index of the
    /// representation that backs it.
    public struct PromisedType: Equatable, Sendable {
        /// The content UTI to promise — ignored by the caller when `isFileURL`.
        public let uti: String

        /// Index into the input descriptor list of the representation that backs
        /// this type.
        public let representationIndex: Int

        /// Whether this promises `public.file-url` rather than the content UTI —
        /// the caller substitutes `.fileURL` for `uti` when realizing the item.
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
    /// Offers arrive richest-first, so the first rep of a duplicated UTI wins the
    /// shared inline item. Non-promisable representations are skipped in place:
    /// every surviving `representationIndex` still indexes the *input* list.
    public static func plan(
        for reps: [ClipboardRepresentationDescriptor]
    ) -> ClipboardPasteboardItemPlan {
        var items: [Item] = []

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

        // One item per file payload; image files also promise their image UTI.
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
