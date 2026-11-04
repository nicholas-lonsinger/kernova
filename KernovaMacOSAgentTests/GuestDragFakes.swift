import AppKit
import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing
import UniformTypeIdentifiers

/// The guest's drag pasteboard, written by hand: a source writing a drag moves
/// the change count, and a source still filling the drag it wrote adds items
/// without moving it.
final class FakeDragPasteboard: ClipboardReadPasteboard, Sendable {
    private struct State: Sendable {
        var items: [FakePasteboardItem] = []
        var changeCount = 0
    }

    private let state = Locked(State())

    var changeCount: Int { state.withLock { $0.changeCount } }
    var items: [any ClipboardPasteboardItemReading] { state.withLock { $0.items } }

    /// A source writes a drag of `items`, moving the change count.
    func write(_ items: [FakePasteboardItem]) {
        state.withLock { state in
            state.items = items
            state.changeCount += 1
        }
    }

    /// The source of the drag already written goes on filling it to `items`,
    /// leaving the change count where it is.
    func fill(_ items: [FakePasteboardItem]) {
        state.withLock { $0.items = items }
    }
}

/// The guest's event stream and drag pasteboard, driven by hand: a test
/// presses and releases the button, fires the press timer, decides when each
/// off-main resolve comes back, and sets the file promises the drag carries.
@MainActor
final class FakeGuestDragInput: GuestDragInput {
    let pasteboard = FakeDragPasteboard()
    var dragPasteboard: any ClipboardReadPasteboard { pasteboard }
    var isPrimaryButtonHeld = false

    private var pressHandler: (@MainActor @Sendable () -> Void)?
    private var tick: (@MainActor @Sendable () -> Void)?
    private(set) var tickInterval: TimeInterval?
    private(set) var isHoldingActivity = false
    /// Every set of file URLs resolved, in order.
    private(set) var resolved: [[URL]] = []
    private var pendingResolves:
        [(urls: [URL], completion: @MainActor @Sendable (ClipboardPasteboardReader.FileIntake) -> Void)] = []
    /// The file promises the drag pasteboard holds, as a drop on the catcher
    /// reads them.
    var receivers: [FakePromiseReceiver] = []
    /// Every set of folders measured, by item index.
    private(set) var measured: [[Int: URL]] = []

    var isObservingPresses: Bool { pressHandler != nil }
    var isTicking: Bool { tick != nil }
    var pendingResolveCount: Int { pendingResolves.count }

    // MARK: Driving it

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
        pasteboard.write(items)
    }

    /// The drag's source goes on filling the drag it wrote to `items`, the
    /// change count unmoved.
    func fill(_ items: [FakePasteboardItem]) {
        pasteboard.fill(items)
    }

    /// Hands back every queued resolve, each the real resolve of its URLs.
    func deliverResolves() {
        let pending = pendingResolves
        pendingResolves.removeAll()
        for resolve in pending {
            resolve.completion(ClipboardPasteboardReader.resolve(filesAt: resolve.urls, sizeOf: nil))
        }
    }

    // MARK: GuestDragInput

    func observePrimaryPresses(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> GuestDragCancel {
        pressHandler = handler
        return { [weak self] in self?.pressHandler = nil }
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

    /// Queues the resolve until ``deliverResolves()``, which runs the live
    /// input's: a stat each, reading nothing inside a folder.
    func resolveFiles(
        _ urls: [URL],
        then completion: @escaping @MainActor @Sendable (ClipboardPasteboardReader.FileIntake) -> Void
    ) {
        resolved.append(urls)
        pendingResolves.append((urls, completion))
    }

    /// Measures each folder as the live input does, and hands the sizes back
    /// at once.
    func measureFolders(
        _ folders: [Int: URL], then completion: @escaping @MainActor @Sendable ([Int: Int]) -> Void
    ) {
        measured.append(folders)
        completion(folders.mapValues { ClipboardArchive.estimatedByteCount(at: $0) })
    }
}

/// The catcher's window, recording whether it is up and what its box shows.
@MainActor
final class FakeCatcherSurface: GuestDragCatcherSurface {
    private(set) var isShown = false
    private(set) var showCount = 0
    /// The items the latest showing presented.
    private(set) var shownItems: [GuestDragItem]?
    /// Whether a screen is there to cover.
    var hasScreen = true

    func show(items: [GuestDragItem]) -> Bool {
        showCount += 1
        shownItems = items
        isShown = hasScreen
        return hasScreen
    }

    func hide() {
        isShown = false
    }
}

/// The connection a drag goes out on, recording what crossed it.
@MainActor
final class FakeGuestDragPeer: GuestDragOutPeer {
    enum Event: Equatable {
        case offered(token: Data)
        case withdrew(token: Data)
        case answered(DragTakeID, DragTakeAnswer)
    }

    /// A take's answer: a step, or its end, each item a report lists by its
    /// one representation's name and a refusal by its code alone.
    enum Answer: Equatable {
        case armed
        case targeted([String])
        case delivering
        case deliverRefused
        case stoodDown
        case named([String])
        case caught(folderSizes: [UInt64]?)
        case returned
        case refused(ErrorCode)
    }

    private(set) var events: [Event] = []
    /// Every offer, in order.
    private(set) var offers: [ItemOffer] = []

    /// The token of the `index`th offer, or none.
    func token(_ index: Int) -> Data? {
        offers.indices.contains(index) ? offers[index].token : nil
    }

    /// Every answer to the take `id`, in order.
    func answers(to id: DragTakeID) -> [Answer] {
        events.compactMap { event in
            guard case .answered(let answered, let answer) = event, answered == id else { return nil }
            switch answer {
            case .report(.armed): return .armed
            case .report(.targeted(let items)): return .targeted(items.map(Self.name))
            case .report(.delivering): return .delivering
            case .report(.deliverRefused): return .deliverRefused
            case .report(.stoodDown): return .stoodDown
            case .report(.named(let names)): return .named(names.map { String(decoding: $0, as: UTF8.self) })
            case .caught(let folderSizes): return .caught(folderSizes: folderSizes)
            case .returned: return .returned
            case .refused(let error): return .refused(error.code)
            }
        }
    }

    /// The items each `TARGETED` of take `id` listed, in order.
    func targeted(_ id: DragTakeID) -> [[OfferedItem]] {
        events.compactMap { event in
            guard case .answered(id, .report(.targeted(let items))) = event else { return nil }
            return items
        }
    }

    /// How many takes were answered, all told.
    var answerCount: Int {
        events.count { if case .answered = $0 { true } else { false } }
    }

    private static func name(_ item: OfferedItem) -> String {
        String(decoding: item.representations.first?.name ?? Data(), as: UTF8.self)
    }

    func offerDrag(_ offer: ItemOffer, _ completion: @escaping @MainActor (WireError?) -> Void) {
        offers.append(offer)
        events.append(.offered(token: offer.token))
        completion(nil)
    }

    func withdrawDrag(_ token: Data) {
        events.append(.withdrew(token: token))
    }

    func answerTake(_ id: DragTakeID, _ answer: DragTakeAnswer) {
        events.append(.answered(id, answer))
    }
}

/// One file promise a drag carries, whose source a test plays: it names its
/// files when called in, and writes each when the test says.
final class FakePromiseReceiver: FilePromiseReceiving {
    /// The names it gives its files once called in.
    private let names: [String]

    private(set) var fileNames: [String] = []
    let fileTypes: [String] = []
    /// Where it was called in to, once it was.
    private(set) var destination: URL?
    /// Called as it is called in, before its call-in returns.
    var onCalledIn: (() -> Void)?
    private var reader: ((URL, (any Error)?) -> Void)?

    init(names: [String]) {
        self.names = names
    }

    var wasCalledIn: Bool { destination != nil }

    func receivePromisedFiles(
        atDestination destination: URL, options: [AnyHashable: Any],
        operationQueue: OperationQueue, reader: @escaping (URL, (any Error)?) -> Void
    ) {
        self.destination = destination
        self.reader = reader
        fileNames = names
        onCalledIn?()
    }

    /// Writes its file named `name` holding `contents`, and reports it.
    @discardableResult
    func write(_ name: String, contents: Data) throws -> URL {
        let url = try #require(destination).appendingPathComponent(name)
        try contents.write(to: url)
        try report(url, nil)
        return url
    }

    /// Writes its folder named `name`, holding one file, and reports it.
    @discardableResult
    func writeFolder(_ name: String) throws -> URL {
        let url = try #require(destination).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: url.appendingPathComponent("inside.txt"))
        try report(url, nil)
        return url
    }

    /// Reports that its file named `name` could not be written.
    func fail(_ name: String) throws {
        let url = try #require(destination).appendingPathComponent(name)
        try report(url, CocoaError(.fileWriteUnknown))
    }

    /// Calls the reader it was called in with.
    private func report(_ url: URL, _ error: (any Error)?) throws {
        let reader = try #require(self.reader)
        reader(url, error)
    }
}

extension GuestDragOutSystem {
    /// A system whose every piece is the fake given.
    static func faked(
        input: FakeGuestDragInput, surface: FakeCatcherSurface
    ) -> GuestDragOutSystem {
        GuestDragOutSystem(
            makeInput: { input },
            makeCatcherSurface: { _ in surface })
    }
}

/// One dragged item carrying a plain file URL.
func fileItem(_ url: URL) -> FakePasteboardItem {
    FakePasteboardItem([(type: .fileURL, data: Data(url.absoluteString.utf8))])
}

/// The promise type every promise item declares besides its promised type.
private let promiseMetadataType = NSPasteboard.PasteboardType(
    NSFilePromiseReceiver.readableDraggedTypes.first ?? "com.apple.NSFilePromiseItemMetaData")

/// One dragged item carrying a file promise of `type` — `nil` names none —
/// and, when `alongside` is given, a file URL besides, as a Photos asset
/// carries one into the library's derivatives.
func promiseItem(_ type: String?, alongside url: URL? = nil) -> FakePasteboardItem {
    var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = [
        (type: promiseMetadataType, data: Data())
    ]
    if let type {
        representations.append((type: GuestDraggedItems.promisedContentType, data: Data(type.utf8)))
    }
    if let url {
        representations.append((type: .fileURL, data: Data(url.absoluteString.utf8)))
    }
    return FakePasteboardItem(representations)
}

/// The guest's type icons: a fresh image for each type asked, every one
/// recorded. It is handed a type and nothing else, so a box icon drawn from
/// it read no file.
@MainActor
final class FakeGuestDragTypeIcons {
    private(set) var asked: [UTType] = []
    private(set) var images: [NSImage] = []

    func icon(for type: UTType) -> NSImage {
        asked.append(type)
        let image = NSImage(size: NSSize(width: 128, height: 128))
        images.append(image)
        return image
    }
}

extension GuestDragCatcher {
    /// A drop on the surface whose pasteboard holds no file promises.
    func performDragOperation() -> Bool {
        performDragOperation(receivers: { [] })
    }
}
