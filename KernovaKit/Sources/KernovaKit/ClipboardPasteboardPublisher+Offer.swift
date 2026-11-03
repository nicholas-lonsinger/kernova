import AppKit
import Foundation
import KernovaWire

/// Pulls a peer's offered representations when a paste asks for them.
///
/// Both calls run inside the pasteboard server's `provideData` callback, on
/// whichever thread it fires on, and block until the pull ends: a lazy
/// promise's bytes must be on the item when the callback returns.
public protocol ClipboardItemPulling: Sendable {
    /// The bytes of the INLINE representation `representation` of item `item`,
    /// or nil when the pull failed.
    func pullBytes(item: Int, representation: Int) -> Data?

    /// The URL the FILE or FOLDER representation `representation` of item
    /// `item` landed at, under the name the receiver chose, or nil when the
    /// pull failed.
    func pullFile(item: Int, representation: Int) -> URL?
}

extension ClipboardPasteboardPublisher {
    /// Publishes a peer's offer: one pasteboard item per offered item, every
    /// type promised and pulled through `puller` only when a paste asks for it.
    ///
    /// `servingFileURLs` false withholds `public.file-url`, as a paste over
    /// the cap requires. A concealed or transient offer marks each item with
    /// the `org.nspasteboard.*` type saying so. The write is promised: it
    /// serves the offer, so ``retractPromisedWrite()`` withdraws it once the
    /// offer ends.
    @discardableResult
    public func publish(
        _ items: [OfferedItem], concealed: Bool, transient: Bool, servingFileURLs: Bool = true,
        puller: any ClipboardItemPulling
    ) -> Bool {
        write(
            Self.itemSpecs(
                for: items, concealed: concealed, transient: transient, servingFileURLs: servingFileURLs,
                puller: puller),
            promised: true)
    }

    /// The item specs promising `items`, as ``publish(_:concealed:transient:servingFileURLs:puller:)``
    /// writes them.
    ///
    /// An item none of whose representations is kept is left out, so a paste
    /// finds no flavor rather than one serving nothing.
    nonisolated public static func itemSpecs(
        for items: [OfferedItem], concealed: Bool, transient: Bool, servingFileURLs: Bool = true,
        puller: any ClipboardItemPulling
    ) -> [ItemSpec] {
        var markers: [String] = []
        if concealed { markers.append(ClipboardSnapshotPolicy.concealedMarkerUTI) }
        if transient { markers.append(ClipboardSnapshotPolicy.transientMarkerUTI) }
        return items.enumerated().compactMap { index, item -> ItemSpec? in
            let promised = ClipboardPromisePolicy.promisedTypes(for: item, servingFileURLs: servingFileURLs)
            guard !promised.isEmpty else { return nil }
            let routes = Dictionary(uniqueKeysWithValues: promised.map { ($0.pasteboardType, $0) })
            let markerSet = Set(markers)
            return ItemSpec(types: promised.map(\.pasteboardType) + markers) { type in
                if markerSet.contains(type) { return Data() }
                guard let route = routes[type] else { return nil }
                guard route.isFileURL else {
                    return puller.pullBytes(item: index, representation: route.representation)
                }
                return puller.pullFile(item: index, representation: route.representation)
                    .map { Data($0.absoluteString.utf8) }
            }
        }
    }
}
