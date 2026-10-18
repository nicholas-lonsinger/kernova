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
@MainActor
final class DisplayDragOutSource: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    /// The VM the drag came out of, so its own display can refuse it.
    let vmID: UUID

    /// The take whose items this session carries.
    nonisolated let take: any GuestDragTaking

    /// Where every item's write runs, one at a time: each blocks on its pull
    /// for as long as the item takes to stream.
    private let writeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.kernova.drag-out-writes"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// What one promise names: which item it is, and the source that writes it.
    ///
    /// Carried as the provider's `userInfo`, which the provider holds strongly,
    /// because its `delegate` is weak and a destination can ask for the file
    /// after the session that carried it has ended.
    final class PromisedItem: Sendable {
        let index: Int
        let source: DisplayDragOutSource

        init(index: Int, source: DisplayDragOutSource) {
            self.index = index
            self.source = source
        }
    }

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
        return take.items.indices.map { index in
            let item = take.items[index]
            let provider = NSFilePromiseProvider(fileType: item.type.identifier, delegate: self)
            provider.userInfo = PromisedItem(index: index, source: self)
            let draggingItem = NSDraggingItem(pasteboardWriter: provider)
            draggingItem.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(for: item.type))
            return draggingItem
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        take.hostSessionEnded(dropped: !operation.isEmpty)
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String {
        guard let promised = filePromiseProvider.userInfo as? PromisedItem,
            take.items.indices.contains(promised.index)
        else { return "File" }
        return take.items[promised.index].filename
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

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }
}
