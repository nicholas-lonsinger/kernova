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
    /// The watcher reads no promise off the drag pasteboard; the catcher's drop
    /// reads them.
    @MainActor var filePromiseReceivers: [any FilePromiseReceiving] { [] }

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
/// presses and releases the button, fires the press timer, sets the file
/// promises the drag carries, and decides when each coordinated read of a
/// whole drop's arrival is granted.
@MainActor
final class FakeGuestDragInput: GuestDragInput {
    let pasteboard = FakeDragPasteboard()
    var dragPasteboard: any ClipboardReadPasteboard { pasteboard }
    private(set) var isPrimaryButtonHeld = false

    private var pressHandler: (@MainActor @Sendable () -> Void)?
    private var tick: (@MainActor @Sendable () -> Void)?
    private(set) var isHoldingActivity = false
    /// The file promises the drag pasteboard holds, as a drop on the catcher
    /// reads them.
    var receivers: [FakePromiseReceiver] = []
    /// Every set of dragged files sized, in order: the only reads of a
    /// dragged file this side makes.
    private(set) var sized: [[URL]] = []
    /// The folder being watched for entries, and who hears them.
    private var watching: (folder: URL, appeared: @MainActor @Sendable ([URL]) -> Void)?
    /// Every entry whose coordinated read was asked for and not yet granted.
    private var coordinating: [(url: URL, granted: @MainActor @Sendable (GuestDragArrival?) -> Void)] = []

    /// The folder a drop's entries are watched in, while one is.
    var watchedFolder: URL? { watching?.folder }
    /// Every entry whose coordinated read waits to be granted, in order asked.
    var coordinationsWaiting: [URL] { coordinating.map(\.url) }

    var isObservingPresses: Bool { pressHandler != nil }
    var isTicking: Bool { tick != nil }

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

    /// Entries named `names` appear in the watched folder, as the live watch
    /// reports what a listing finds; nothing when no folder is watched.
    func appear(_ names: [String]) {
        guard let watching else { return }
        watching.appeared(names.map { watching.folder.appendingPathComponent($0) })
    }

    /// Grants the coordinated read of the watched folder's entry `name`, as
    /// the live input does once a coordinating writer is done: it hands back
    /// what the entry is now.
    func grant(_ name: String) {
        guard let index = coordinating.firstIndex(where: { $0.url.lastPathComponent == name }) else { return }
        let (url, granted) = coordinating.remove(at: index)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return granted(nil) }
        granted(GuestDragArrival(url: url, isFolder: isDirectory.boolValue))
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
        self.tick = tick
        return { [weak self] in self?.tick = nil }
    }

    func holdActivity(reason: String) -> GuestDragCancel {
        isHoldingActivity = true
        return { [weak self] in self?.isHoldingActivity = false }
    }

    /// Sizes each file as the live input does, and hands the sizes back at
    /// once.
    func sizeFiles(_ urls: [URL], then completion: @escaping @MainActor @Sendable ([Int?]) -> Void) {
        sized.append(urls)
        completion(urls.map { ClipboardPasteboardReader.resolve(filesAt: [$0]).representations.first?.byteCount })
    }

    func watchEntries(
        in folder: URL, _ appeared: @escaping @MainActor @Sendable ([URL]) -> Void
    ) -> GuestDragCancel {
        watching = (folder, appeared)
        return { [weak self] in self?.watching = nil }
    }

    /// Queues the read until ``grant(_:)``.
    func coordinateRead(of url: URL, then granted: @escaping @MainActor @Sendable (GuestDragArrival?) -> Void) {
        coordinating.append((url, granted))
    }
}

/// A delivering drop's promises: whether its first promised item offers the
/// whole-drop exchange, recording every call.
@MainActor
final class FakeGuestDragDrop: GuestDragDrop {
    enum Call: Equatable {
        case items
        case offers(item: Int)
        case setPasteLocation(URL)
        case request(item: Int)
        case receivers
    }

    /// The items that offer their promised file URL, by index in drag order.
    var offering: Set<Int>
    /// The source writing the whole drop at the paste location, once asked.
    var onRequest: ((URL) -> Void)?
    private let promises: [FakePromiseReceiver]
    /// The drop's items, as its pasteboard holds them.
    private let dropped: [GuestDragItem]?
    private(set) var calls: [Call] = []
    private var location: URL?

    init(
        _ dropped: [GuestDragItem]?, offering: Set<Int> = [], receivers: [FakePromiseReceiver] = []
    ) {
        self.dropped = dropped
        self.offering = offering
        promises = receivers
    }

    func items() -> [GuestDragItem]? {
        calls.append(.items)
        return dropped
    }

    func offersPromisedFileURL(item index: Int) -> Bool {
        calls.append(.offers(item: index))
        return offering.contains(index)
    }

    func setPasteLocation(_ folder: URL) -> Bool {
        calls.append(.setPasteLocation(folder))
        location = folder
        return true
    }

    func requestPromisedFileURL(item index: Int) -> Bool {
        calls.append(.request(item: index))
        guard let location, offering.contains(index) else { return false }
        onRequest?(location)
        return true
    }

    func receivers() -> [any FilePromiseReceiving] {
        calls.append(.receivers)
        return promises
    }
}

/// The catcher's window, recording whether it is up and what its box shows.
@MainActor
final class FakeCatcherSurface: GuestDragCatcherSurface {
    private(set) var isShown = false
    private(set) var showCount = 0
    /// The items the latest showing presented.
    private(set) var shownItems: [GuestDragItem]?

    func show(items: [GuestDragItem]) -> Bool {
        showCount += 1
        shownItems = items
        isShown = true
        return true
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
        case caught(sizes: [UInt64]?)
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
            case .caught(let sizes): return .caught(sizes: sizes)
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
    /// A drop on the surface whose pasteboard holds no items.
    func performDragOperation() -> Bool {
        performDragOperation(drop: FakeGuestDragDrop(nil))
    }
}
