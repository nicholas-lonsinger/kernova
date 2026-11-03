import AppKit
import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaTestSupport
import KernovaWire
import Testing
import UniformTypeIdentifiers

/// The guest's event stream and drag pasteboard, driven by hand: a test
/// presses and releases the button, fires the press timer, decides when each
/// off-main resolve comes back, and sets the file promises the drag carries.
@MainActor
final class FakeGuestDragInput: GuestDragInput {
    let pasteboard = FakeReadPasteboard()
    var dragPasteboard: any ClipboardReadPasteboard { pasteboard }
    var isPrimaryButtonHeld = false

    /// Fires on every registration, cancellation, and queued resolve.
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
    /// The file promises the drag pasteboard holds, as a drop on the catcher
    /// reads them.
    var receivers: [FakePromiseReceiver] = []
    /// Every set of folders measured, by item index.
    private(set) var measured: [[Int: URL]] = []

    /// How many connections have built a drag-out on this input.
    private(set) var connectionCount = 0

    var isObservingPresses: Bool { pressHandler != nil }
    var isTicking: Bool { tick != nil }
    var pendingResolveCount: Int { pendingResolves.count }

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
    nonisolated let changed = AsyncGate()

    func show(items: [GuestDragItem]) -> Bool {
        showCount += 1
        shownItems = items
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
        /// An offer, each item by its one representation's name.
        case offered(token: Data, names: [String])
        case withdrew(token: Data)
        case answered(DragTakeID, DragTakeAnswer)
    }

    /// A take's answer: a step, or its end, a refusal by its code alone and a
    /// catch by whether it named a new offer.
    enum Answer: Equatable {
        case armed
        case targeted
        case delivering
        case deliverRefused
        case stoodDown
        case caught(reoffered: Bool)
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
            case .report(.targeted): return .targeted
            case .report(.delivering): return .delivering
            case .report(.deliverRefused): return .deliverRefused
            case .report(.stoodDown): return .stoodDown
            case .caught(let reoffer): return .caught(reoffered: reoffer != nil)
            case .returned: return .returned
            case .refused(let error): return .refused(error.code)
            }
        }
    }

    /// How many takes were answered, all told.
    var answerCount: Int {
        events.count { if case .answered = $0 { true } else { false } }
    }

    /// The new offer a catch of take `id` named, if any.
    func reoffer(of id: DragTakeID) -> Data? {
        for case .answered(let answered, .caught(let reoffer?)) in events where answered == id { return reoffer }
        return nil
    }

    func offerDrag(_ offer: ItemOffer, _ completion: @escaping @MainActor (WireError?) -> Void) {
        offers.append(offer)
        events.append(
            .offered(
                token: offer.token,
                names: offer.items.map { String(decoding: $0.representations.first?.name ?? Data(), as: UTF8.self) }))
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
