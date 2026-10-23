import AppKit
import KernovaCore
import KernovaKit
import UniformTypeIdentifiers

/// The Mac drag session carrying one taken-over guest drag: one file promise
/// per dragged item, each written where the destination asks by pulling it
/// from the guest.
///
/// Copy is the only operation it offers, in or out of the app, so no
/// destination can ask for the guest's items to be moved or deleted.
///
/// Its images show exactly while the session is off the take's display: over
/// it, the guest draws its own drag image under the guest pointer the session
/// moves.
@MainActor
final class DisplayDragOutSource: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    /// The VM the drag came out of, so its own display can hand the drag back
    /// to the guest.
    let vmID: UUID

    /// The take whose items this session carries.
    nonisolated let take: any GuestDragTaking

    /// Where every item's write runs, one at a time: each blocks on its pull
    /// for as long as the item takes to stream.
    nonisolated private let writeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.kernova.drag-out-writes"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// What one promise names: which item it is, what it is called, and the
    /// source that writes it.
    ///
    /// Carried as the provider's `userInfo`, which the provider holds strongly,
    /// because its `delegate` is weak and a destination can ask for the file
    /// after the session that carried it has ended.
    final class PromisedItem: Sendable {
        let index: Int
        let filename: String
        let source: DisplayDragOutSource

        init(index: Int, filename: String, source: DisplayDragOutSource) {
            self.index = index
            self.filename = filename
            self.source = source
        }
    }

    /// Each item's image, as ``draggingItems(centeredAt:)`` drew it, by index.
    private var imageProviders: [(() -> [NSDraggingImageComponent])?] = []

    init(vmID: UUID, take: any GuestDragTaking) {
        self.vmID = vmID
        self.take = take
    }

    /// One dragging item per dragged item, each a file promise drawn as the
    /// system icon for its type and framed around `point`, in the beginning
    /// view's coordinates.
    func draggingItems(centeredAt point: NSPoint) -> [NSDraggingItem] {
        let side: CGFloat = 64
        let frame = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        let draggingItems = take.items.indices.map { index in
            let item = take.items[index]
            let provider = NSFilePromiseProvider(fileType: item.type.identifier, delegate: self)
            provider.userInfo = PromisedItem(index: index, filename: item.filename, source: self)
            let draggingItem = NSDraggingItem(pasteboardWriter: provider)
            draggingItem.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(for: item.type))
            return draggingItem
        }
        imageProviders = draggingItems.map(\.imageComponentsProvider)
        return draggingItems
    }

    /// Sets `session`'s item images from the take now, and again in the same
    /// call that changes whether its session is over the display.
    ///
    /// The source sets them because a destination's changes to them outlast
    /// the drag's exit from it, though `NSDragging.h` says they revert there
    /// (observed live, 2026-10).
    func followImages(of session: any DraggingItemImageSetting) {
        applyImages(to: session, hidden: take.sessionOverDisplay)
        take.sessionOverDisplayChanged = { [weak self] over in
            self?.applyImages(to: session, hidden: over)
        }
    }

    private func applyImages(to session: any DraggingItemImageSetting, hidden: Bool) {
        session.forEachDraggingItem { item, index in
            item.imageComponentsProvider =
                hidden || !imageProviders.indices.contains(index) ? nil : imageProviders[index]
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        followImages(of: session)
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        take.hostSessionMoved()
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        take.sessionOverDisplayChanged = nil
        take.hostSessionEnded(dropped: !operation.isEmpty)
    }

    // MARK: - NSFilePromiseProviderDelegate

    // Every method here is `nonisolated`: AppKit asks from whichever queue is
    // serving the promise, and for a destination in this app — another VM's
    // display — that is file coordination's own (crash reports 2026-10-18:
    // `_dispatch_assert_queue_fail` on `com.apple.FileCoordination` under
    // `-[NSFileProviderXPCMessenger _makeProvider:provideItemAtURL:…]`).

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String {
        (filePromiseProvider.userInfo as? PromisedItem)?.filename ?? "File"
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let promised = filePromiseProvider.userInfo as? PromisedItem else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        do {
            try promised.source.take.writeItem(at: promised.index, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }
}

/// A drag session whose items' images can be set, one item at a time.
@MainActor
protocol DraggingItemImageSetting: AnyObject {
    /// Calls `body` with each of the session's items and its index; changes to
    /// an item's properties are reflected in the drag.
    func forEachDraggingItem(_ body: (NSDraggingItem, Int) -> Void)
}

extension NSDraggingSession: DraggingItemImageSetting {
    func forEachDraggingItem(_ body: (NSDraggingItem, Int) -> Void) {
        enumerateDraggingItems(
            options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, index, _ in
            body(item, index)
        }
    }
}
