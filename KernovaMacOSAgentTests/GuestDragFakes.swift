import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport

/// The guest's event stream and drag pasteboard, driven by hand: a test
/// presses and releases the button, fires the press timer, and decides when
/// each off-main resolve and folder measure comes back.
@MainActor
final class FakeGuestDragInput: GuestDragInput {
    let pasteboard = FakeReadPasteboard()
    var dragPasteboard: any ClipboardReadPasteboard { pasteboard }
    var isPrimaryButtonHeld = false

    /// Fires on every registration, cancellation, and queued resolve or
    /// measure.
    nonisolated let changed = AsyncGate()

    /// Hands each resolve back on the next main-queue turn instead of holding
    /// it for ``deliverResolves(_:)``.
    var resolvesOnItsOwn = false

    private var pressHandler: (@MainActor @Sendable () -> Void)?
    private var tick: (@MainActor @Sendable () -> Void)?
    private(set) var tickInterval: TimeInterval?
    private(set) var isHoldingActivity = false
    private(set) var resolveCount = 0
    private var pendingResolves:
        [(urls: [URL], completion: @MainActor @Sendable (ClipboardPasteboardReader.FileIntake) -> Void)] = []
    private var pendingMeasures: [(folders: [Int: URL], completion: @MainActor @Sendable ([Int: Int]) -> Void)] = []

    /// How many connections have built a drag-out on this input.
    private(set) var connectionCount = 0

    var isObservingPresses: Bool { pressHandler != nil }
    var isTicking: Bool { tick != nil }
    var pendingResolveCount: Int { pendingResolves.count }
    /// The folders of each measure queued and not yet delivered, in order.
    var pendingMeasureFolders: [[Int: URL]] { pendingMeasures.map(\.folders) }

    // MARK: Driving it

    /// A connection built a drag-out on this input.
    func connected() {
        connectionCount += 1
        changed.notify()
    }

    /// The button goes down in another app, and the monitor reports it.
    func press() {
        isPrimaryButtonHeld = true
        pressHandler?()
    }

    /// The button comes up; nothing hears of it until the next tick.
    func release() {
        isPrimaryButtonHeld = false
    }

    /// One firing of the press timer, if it is running.
    func fireTick() {
        tick?()
    }

    /// Writes one drag's items as a source would, bumping the change count.
    func drag(_ items: [FakePasteboardItem]) {
        pasteboard.setItems(items)
    }

    /// Hands back every queued resolve, each the real resolve of its URLs
    /// unless `intake` stands in for it.
    func deliverResolves(_ intake: ClipboardPasteboardReader.FileIntake? = nil) {
        let pending = pendingResolves
        pendingResolves.removeAll()
        for resolve in pending {
            resolve.completion(intake ?? Self.offerResolve(resolve.urls))
        }
    }

    /// Hands back every queued measure, each folder at `size` — or walked for
    /// real when `size` is `nil`.
    func deliverMeasures(size: Int? = nil) {
        let pending = pendingMeasures
        pendingMeasures.removeAll()
        for measure in pending {
            measure.completion(
                measure.folders.mapValues { size ?? ClipboardArchive.estimatedByteCount(at: $0) })
        }
    }

    /// The resolve the live input runs for an offer, which reads nothing inside
    /// a folder.
    private nonisolated static func offerResolve(_ urls: [URL]) -> ClipboardPasteboardReader.FileIntake {
        ClipboardPasteboardReader.resolve(filesAt: urls, sizeOf: nil)
    }

    // MARK: GuestDragInput

    func observePrimaryPresses(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> GuestDragCancel {
        pressHandler = handler
        changed.notify()
        return { [weak self] in
            self?.pressHandler = nil
            self?.changed.notify()
        }
    }

    func repeatEvery(
        _ interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void
    ) -> GuestDragCancel {
        tickInterval = interval
        self.tick = tick
        return { [weak self] in self?.tick = nil }
    }

    func holdActivity(reason: String) -> GuestDragCancel {
        isHoldingActivity = true
        return { [weak self] in self?.isHoldingActivity = false }
    }

    func resolveFiles(
        _ urls: [URL],
        then completion: @escaping @MainActor @Sendable (ClipboardPasteboardReader.FileIntake) -> Void
    ) {
        resolveCount += 1
        if resolvesOnItsOwn {
            MainActorBridge.async { completion(Self.offerResolve(urls)) }
        } else {
            pendingResolves.append((urls, completion))
        }
        changed.notify()
    }

    func measureFolders(
        _ folders: [Int: URL], then completion: @escaping @MainActor @Sendable ([Int: Int]) -> Void
    ) {
        pendingMeasures.append((folders, completion))
        changed.notify()
    }
}

/// The catcher's window, recording whether it is up.
@MainActor
final class FakeCatcherSurface: GuestDragCatcherSurface {
    private(set) var isShown = false
    private(set) var showCount = 0
    /// Whether a screen is there to cover.
    var hasScreen = true
    nonisolated let changed = AsyncGate()

    func show() -> Bool {
        showCount += 1
        isShown = hasScreen
        changed.notify()
        return hasScreen
    }

    func hide() {
        isShown = false
        changed.notify()
    }
}

/// The connection a drag goes out on, recording what crossed it.
@MainActor
final class FakeGuestDragPeer: GuestDragOutPeer {
    enum Event: Equatable {
        case offered(generation: UInt64, filenames: [String])
        case withdrew(generation: UInt64)
        case handOff(generation: UInt64, step: ClipboardDragHandOffStep)
        case sized(generation: UInt64, folderByteCounts: [Int: Int])
    }

    private(set) var events: [Event] = []
    private var nextGeneration: UInt64 = 1
    /// What each offer carried, until it is withdrawn.
    private var contents: [UInt64: ClipboardContent] = [:]

    /// Every hand-off step reported, in order.
    var handOffs: [Event] {
        events.filter { if case .handOff = $0 { true } else { false } }
    }

    func offer(
        _ content: ClipboardContent, skippedBeforeOffer: Int
    ) -> ClipboardEndpoint.OfferOutcome {
        let generation = nextGeneration
        nextGeneration += 1
        events.append(
            .offered(generation: generation, filenames: content.representations.map(\.filename)))
        contents[generation] = content
        return .sent(generation: generation)
    }

    func withdraw(generation: UInt64) -> Bool {
        events.append(.withdrew(generation: generation))
        contents[generation] = nil
        return true
    }

    func sendDragHandOff(generation: UInt64, step: ClipboardDragHandOffStep) {
        events.append(.handOff(generation: generation, step: step))
    }

    func outboundContent(generation: UInt64) -> ClipboardContent? {
        contents[generation]
    }

    func sendDragSizes(generation: UInt64, folderByteCounts: [Int: Int]) -> Bool {
        guard let content = contents[generation] else { return false }
        contents[generation] = content.withDirectoryEstimates(folderByteCounts)
        events.append(.sized(generation: generation, folderByteCounts: folderByteCounts))
        return true
    }
}

extension GuestDragOutSystem {
    /// A system whose every piece is the fake given.
    static func faked(
        input: FakeGuestDragInput, surface: FakeCatcherSurface
    ) -> GuestDragOutSystem {
        GuestDragOutSystem(
            makeInput: {
                input.connected()
                return input
            },
            makeCatcherSurface: { _ in surface })
    }
}

/// One dragged item carrying a plain file URL.
func fileItem(_ url: URL) -> FakePasteboardItem {
    FakePasteboardItem([(type: .fileURL, data: Data(url.absoluteString.utf8))])
}

/// One dragged item carrying a file URL beside a file promise.
func promisedFileItem(_ url: URL) -> FakePasteboardItem {
    let promiseType = NSPasteboard.PasteboardType(
        NSFilePromiseReceiver.readableDraggedTypes.first ?? "com.apple.NSFilePromiseItemMetaData")
    return FakePasteboardItem([
        (type: .fileURL, data: Data(url.absoluteString.utf8)), (type: promiseType, data: Data()),
    ])
}

/// A drag over the catcher's window: a real pasteboard of file URLs, and items
/// a destination may restyle — every change undone on ``exit()``, as
/// `NSDragging.h` says a drag's leaving its destination does.
@MainActor
final class FakeDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    /// The frame the source drew every item at.
    static let sourceFrame = NSRect(x: 0, y: 0, width: 16, height: 16)
    /// The formation the source set.
    static let sourceFormation = NSDraggingFormation.stack

    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingSourceOperationMask: NSDragOperation
    private let fileURLs: [URL]
    private(set) var items: [NSDraggingItem] = []
    /// How many times a destination enumerated the items.
    private(set) var enumerations = 0
    var draggingFormation = sourceFormation
    var animatesToDestination = false
    var numberOfValidItemsForDrop: Int

    init(fileURLs: [URL], mask: NSDragOperation = [.copy, .move, .generic]) {
        self.fileURLs = fileURLs
        draggingSourceOperationMask = mask
        numberOfValidItemsForDrop = fileURLs.count
        super.init()
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(fileURLs.map { $0 as NSURL })
        exit()
    }

    /// The drag left its destination: the items are the source's again.
    func exit() {
        items = fileURLs.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(Self.sourceFrame, contents: NSImage(size: Self.sourceFrame.size))
            return item
        }
        draggingFormation = Self.sourceFormation
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        enumerations += 1
        var stop: ObjCBool = false
        for (index, item) in items.enumerated() {
            block(item, index, &stop)
            if stop.boolValue { break }
        }
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
}
