import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

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
        /// An offer, each item by its filename — a promise, which has none, as
        /// `promise:<its type>`.
        case offered(generation: UInt64, items: [String])
        case withdrew(generation: UInt64)
        case handOff(generation: UInt64, step: ClipboardDragHandOffStep)
        case sized(generation: UInt64, folderByteCounts: [Int: Int])
        case named(generation: UInt64, filenames: [Int: String])
        case resolved(generation: UInt64, repIndex: Int, filename: String, byteCount: Int)
        case unavailable(generation: UInt64, repIndices: [Int])
    }

    private(set) var events: [Event] = []
    private var nextGeneration: UInt64 = 1
    /// What each offer carried, until it is withdrawn.
    private var contents: [UInt64: ClipboardContent] = [:]

    /// Every hand-off step reported, in order.
    var handOffs: [Event] {
        events.filter { if case .handOff = $0 { true } else { false } }
    }

    func offerDrag(_ items: [ClipboardDragOutItem]) -> ClipboardEndpoint.OfferOutcome {
        let generation = nextGeneration
        nextGeneration += 1
        let representations = items.map { item -> ClipboardContent.Representation in
            switch item {
            case .file(let representation):
                return representation
            case .promise(let uti, let isDirectory):
                return ClipboardContent.Representation(
                    pendingRemoteUTI: uti, byteCount: 0, filename: "promise:\(uti)", isDirectory: isDirectory)
            }
        }
        events.append(.offered(generation: generation, items: representations.map(\.filename)))
        contents[generation] = ClipboardContent(representations: representations)
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

    func sendDragNames(generation: UInt64, filenames: [Int: String]) -> Bool {
        events.append(.named(generation: generation, filenames: filenames))
        return true
    }

    func resolvePromisedDragItem(generation: UInt64, repIndex: Int, fileURL: URL, byteCount: Int) -> Bool {
        events.append(
            .resolved(
                generation: generation, repIndex: repIndex, filename: fileURL.lastPathComponent,
                byteCount: byteCount))
        return true
    }

    func markPromisedDragItemsUnavailable(generation: UInt64, repIndices: [Int]) -> Bool {
        events.append(.unavailable(generation: generation, repIndices: repIndices))
        return true
    }
}

/// One file promise a drop carries, whose source a test plays: it names its
/// files when called in, and writes each when the test says.
final class FakePromiseReceiver: GuestDragPromiseReceiving {
    /// The names it gives its files once called in.
    private let names: [String]

    private(set) var fileNames: [String] = []
    /// Where it was called in to, once it was.
    private(set) var destination: URL?
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
