import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaKit
import KernovaLogging
import KernovaPlatformDarwin
import KernovaSynchronization
import KernovaWire
import UniformTypeIdentifiers

/// DRAG on this session peer: the watcher that offers each drag of plain file
/// URLs and file promises the host, the catcher that ends the guest's drag once
/// the host takes it over, and the files the host's pulls are served from.
///
/// The host takes a drag over with `DRAG_TAKE` once the pointer leaves the VM
/// display with the button held, and injects a button release onto the catcher
/// only after it reports `TARGETED` — an injected release is a real drop under
/// the guest pointer, so every step before that one either succeeds or refuses
/// the take, and the host then hands the press back to the guest untouched.
///
/// A file promise has no name until it is called in, which `NSFilePromiseReceiver.h`
/// says to do "once you are accepting the file promise", and an offer lists no
/// folder's contents, so a drag the host takes goes out under stand-in names
/// for its promises and no size for its folders. The drop the host asks to
/// deliver — a Mac destination took the drag — calls the promises in, serves
/// them from the taken offer, and names them on the take (`STEP_NAMED`), then
/// walks the folders and ends the take `CAUGHT` with their sizes. The taken
/// offer carries the drag throughout, and this side never withdraws it once
/// taken. A drop that does not deliver, and a drag that never leaves the
/// guest, calls nothing in.
///
/// Built once, for the session peer's life; the watcher runs only while DRAG
/// is usable on the connection to the host.
@MainActor
final class GuestDragOut {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestDragOut")

    private let peer: any GuestDragOutPeer
    private let input: any GuestDragInput
    private let watcher: GuestDragWatcher
    private let catcher: GuestDragCatcher
    private let promises: GuestDragPromises
    /// What each open offer's pulls are served from, read on the pulls' queues.
    nonisolated let served = GuestDragServedOffers()
    /// The call-in each delivered drag's promises landed through, by its
    /// offer's token.
    private var callIns: [Data: GuestDragPromises.CallIn] = [:]

    init(peer: any GuestDragOutPeer, system: GuestDragOutSystem, stagingRoot: ProcessStagingRoot) {
        let input = system.makeInput()
        self.peer = peer
        self.input = input
        watcher = GuestDragWatcher(input: input, peer: peer)
        promises = GuestDragPromises(stagingRoot: stagingRoot)
        catcher = GuestDragCatcher(peer: peer, makeSurface: system.makeCatcherSurface) { [weak input] items, done in
            guard let input else { return done(nil) }
            Self.carry(items, input: input, done)
        }
        watcher.onPressEnded = { [weak catcher] press in catcher?.pressEnded(press) }
        let served = served
        catcher.onCarried = { claim, carried in _ = served.serve(claim.token, carried.sources) }
        catcher.onDeliver = { [weak self] id, claim, carried, receivers in
            self?.deliver(id, claim, carried, receivers: receivers)
        }
    }

    /// Watches for drags to offer the host while DRAG is usable, or stops
    /// watching; idempotent either way.
    func setUsable(_ usable: Bool) {
        if usable { watcher.start() } else { watcher.stop() }
    }

    /// The host takes the drag this side offers under `token`.
    func take(_ id: DragTakeID, token: Data) {
        switch watcher.claim(token: token) {
        case .success(let claim):
            served.open(token)
            catcher.arm(claim, take: id)
        case .failure(let refusal):
            Self.logger.log(.notice, "Refused the host's take: \(refusal.message, privacy: .public)")
            peer.answerTake(id, .refused(refusal.error))
        }
    }

    /// The host's word on take `id`.
    func control(_ id: DragTakeID, _ control: DragTakeControl) {
        switch control {
        case .catcher(let shown): catcher.setShown(shown, take: id)
        case .deliver: catcher.deliver(take: id)
        }
    }

    /// Take `id` is over without this side ending it.
    func cancelled(_ id: DragTakeID) {
        catcher.cancelled(take: id)
    }

    /// This side's offer of `token` ended: the host released it, this side
    /// withdrew it, or the connection ended.
    func offerEnded(_ token: Data) {
        watcher.forget(token: token)
        served.remove(token)
        if let callIn = callIns.removeValue(forKey: token) { promises.complete(callIn) }
    }

    /// Ends everything drag-out holds on screen, and lets go of its called-in
    /// promises once their reads settle.
    func stop() {
        watcher.stop()
        catcher.stop()
        served.removeAll()
        for callIn in callIns.values { promises.complete(callIn) }
        callIns.removeAll()
    }

    // MARK: - Carrying

    /// Resolves `items`' file URLs off the main actor, then hands back what a
    /// take of them carries, or nil unless every item can go out.
    private static func carry(
        _ items: [GuestDragItem], input: any GuestDragInput,
        _ done: @escaping @MainActor (GuestDragCatcher.Carried?) -> Void
    ) {
        input.resolveFiles(items.compactMap(\.fileURL)) { intake in
            guard let offered = GuestDraggedItems.offerItems(items, resolvedFiles: intake) else { return done(nil) }
            done(
                GuestDragCatcher.Carried(
                    items: items, intake: intake, offered: offered.map(\.item), sources: offered.map(\.source)))
        }
    }

    // MARK: - Delivering

    /// Delivers the drag `claim` names, caught on a drop take `id` asked to
    /// deliver: calls its promises in through `receivers`, serves them from
    /// the taken offer and names them on the take, then walks its folders and
    /// ends the take `CAUGHT` with their sizes. A drag of plain files alone has
    /// nothing to add, and one whose promises gave no names ends `CAUGHT`
    /// undelivered.
    private func deliver(
        _ id: DragTakeID, _ claim: GuestDragWatcher.Claim, _ carried: GuestDragCatcher.Carried,
        receivers: [any FilePromiseReceiving]
    ) {
        let promised = carried.items.contains { $0.fileURL == nil }
        let folders = Self.folders(of: carried)
        guard promised || !folders.isEmpty else { return peer.answerTake(id, .caught(folderSizes: nil)) }
        var names: [Data] = []
        if promised {
            let taken = carried.items.compactMap { $0.fileURL?.lastPathComponent }
            guard let callIn = promises.callIn(carried.items, receivers: receivers, taken: taken) else {
                Self.logger.log(.notice, "The drag's promises could not all be named; the host gets them unnamed")
                return peer.answerTake(id, .caught(folderSizes: nil))
            }
            guard
                let offered = GuestDraggedItems.offerItems(
                    carried.items, resolvedFiles: carried.intake, promises: callIn.offered)
            else {
                promises.complete(callIn)
                return peer.answerTake(id, .caught(folderSizes: nil))
            }
            guard served.serve(claim.token, offered.map(\.source)) else {
                promises.complete(callIn)
                return peer.answerTake(id, .caught(folderSizes: nil))
            }
            callIns[claim.token] = callIn
            names = carried.items.indices.compactMap { callIn.offered[$0].map { Data($0.name.utf8) } }
        }
        peer.answerTake(id, .report(.named(names)))
        input.measureFolders(folders) { [weak self] sizes in
            let sized = folders.keys.sorted().map { UInt64(max(sizes[$0] ?? 0, 0)) }
            self?.peer.answerTake(id, .caught(folderSizes: sized))
            Self.logger.log(.notice, "Delivered the drag: its promises named and its folders sized")
        }
    }

    /// The folders among `carried`'s plain file items, by item index.
    private static func folders(of carried: GuestDragCatcher.Carried) -> [Int: URL] {
        var folders: [Int: URL] = [:]
        var files = carried.intake.representations.makeIterator()
        for (index, item) in carried.items.enumerated() {
            guard case .file(let url) = item, let resolved = files.next() else { continue }
            if resolved.isDirectory { folders[index] = url }
        }
        return folders
    }

    #if DEBUG
    /// Test seam: the catcher, whose drag callbacks a test delivers itself in
    /// place of a window server's.
    var catcherForTesting: GuestDragCatcher { catcher }

    /// Test seam: the drag's called-in promises.
    var promisesForTesting: GuestDragPromises { promises }
    #endif
}

// MARK: - Seams

/// The connection a drag goes out on: the session peer's runtime.
@MainActor
protocol GuestDragOutPeer: AnyObject {
    /// Offers a drag to the host; `completion` hears nil once it is open, or
    /// why it is not.
    func offerDrag(_ offer: ItemOffer, _ completion: @escaping @MainActor (WireError?) -> Void)

    /// Withdraws this side's drag offer of `token`.
    func withdrawDrag(_ token: Data)

    /// Answers the host's take `id`.
    func answerTake(_ id: DragTakeID, _ answer: DragTakeAnswer)
}

/// Ends one registration a ``GuestDragInput`` made; called at most once.
typealias GuestDragCancel = @MainActor () -> Void

/// What the watcher reads of the guest's input and pasteboard, and the
/// resources it holds while it runs.
@MainActor
protocol GuestDragInput: AnyObject {
    /// The pasteboard the guest's drag manager writes each drag to.
    var dragPasteboard: any ClipboardReadPasteboard { get }

    /// Whether the primary mouse button is down right now.
    var isPrimaryButtonHeld: Bool { get }

    /// Calls `handler` for each primary-button press another app receives.
    ///
    /// The calls arrive after the fact: by the time one runs, the press may
    /// already have started a drag, or ended.
    func observePrimaryPresses(_ handler: @escaping @MainActor @Sendable () -> Void) -> GuestDragCancel

    /// Calls `tick` every `interval` until cancelled, including while a run
    /// loop is tracking.
    func repeatEvery(
        _ interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void
    ) -> GuestDragCancel

    /// Keeps the process out of App Nap, so the ticks keep their interval,
    /// until cancelled.
    func holdActivity(reason: String) -> GuestDragCancel

    /// Resolves `urls` into representations off the main actor — a stat each,
    /// reading nothing inside a folder, whose estimate is `0` — and hands the
    /// result back on it.
    func resolveFiles(
        _ urls: [URL],
        then completion: @escaping @MainActor @Sendable (ClipboardPasteboardReader.FileIntake) -> Void)

    /// Measures each of `folders`, keyed by item index, off the main actor — a
    /// walk of its tree, the only read of a folder's contents a drag makes
    /// before the host pulls it — and hands the sizes back on it.
    func measureFolders(_ folders: [Int: URL], then completion: @escaping @MainActor @Sendable ([Int: Int]) -> Void)
}

/// The on-screen window that receives the guest's drag once the host has taken
/// it over.
@MainActor
protocol GuestDragCatcherSurface: AnyObject {
    /// Orders the surface front over the whole screen under the pointer,
    /// its box showing `items`, returning `false` when there is no screen
    /// to cover.
    func show(items: [GuestDragItem]) -> Bool

    /// Orders the surface out.
    func hide()
}

/// Where a drag-out's platform pieces come from: the live guest's for the
/// agent, fakes for a test.
struct GuestDragOutSystem: Sendable {
    /// Builds the watcher's input, once.
    var makeInput: @MainActor @Sendable () -> any GuestDragInput

    /// Builds the catcher's surface the first time a take arms it, delivering
    /// its drag callbacks to the catcher it is given.
    var makeCatcherSurface: @MainActor @Sendable (GuestDragCatcher) -> any GuestDragCatcherSurface

    /// The guest's own event stream, drag pasteboard and screen.
    static let live = GuestDragOutSystem(
        makeInput: { SystemGuestDragInput() },
        makeCatcherSurface: { GuestDragCatcherPanel(catcher: $0) })
}

// MARK: - What the host's pulls are served from

/// One file promise's landing, as a pull of it waits for: the file its source
/// wrote, or why it never will.
final class GuestDragLanding: Sendable {
    private let state = Locked<Result<URL, WireError>?>(nil)
    private let settled = DispatchSemaphore(value: 0)

    /// Settles the landing, once; a later settle changes nothing.
    func settle(_ result: Result<URL, WireError>) {
        let first = state.withLock { state -> Bool in
            guard state == nil else { return false }
            state = result
            return true
        }
        if first { settled.signal() }
    }

    /// Blocks until the landing settles, and returns how.
    func wait() -> Result<URL, WireError> {
        if let result = state.withLock({ $0 }) { return result }
        settled.wait()
        // Passes the signal on to any other waiter.
        settled.signal()
        return state.withLock { $0 } ?? .failure(WireError(.internal, debugDetail: "a landing woke unsettled"))
    }
}

/// What one offered item's pulls are served from.
enum GuestDragSource: Sendable {
    /// A plain file URL, of a file or a folder.
    case file(URL)
    /// A file promise not called in: nothing serves it.
    case uncalledPromise
    /// A called-in promise, once its source writes it.
    case promise(GuestDragLanding)
}

/// Every open drag offer's sources, by token: what the session peer's item
/// source serves a pull of this side's drag from, on the pull's own queue.
final class GuestDragServedOffers: Sendable {
    private let offers = Locked([Data: [GuestDragSource]]())

    /// Holds a place for the offer of `token`, whose take claimed it, serving
    /// nothing yet; ``remove(_:)`` ends it once the offer ends.
    func open(_ token: Data) {
        offers.withLock { $0[token] = [] }
    }

    /// Serves `sources`, in the offer's item order, for the offer of `token`
    /// while ``open(_:)`` holds its place; false once the offer has ended,
    /// its promises then answered unavailable.
    func serve(_ token: Data, _ sources: [GuestDragSource]) -> Bool {
        let served = offers.withLock { offers in
            guard offers[token] != nil else { return false }
            offers[token] = sources
            return true
        }
        if !served { Self.abandon(sources) }
        return served
    }

    /// Serves nothing more of the offer of `token`; a pull waiting on one of
    /// its promises is answered unavailable.
    func remove(_ token: Data) {
        let removed = offers.withLock { $0.removeValue(forKey: token) } ?? []
        Self.abandon(removed)
    }

    /// Serves nothing more of any offer.
    func removeAll() {
        let removed = offers.withLock { offers in
            defer { offers.removeAll() }
            return offers.values.flatMap { $0 }
        }
        Self.abandon(removed)
    }

    private static func abandon(_ sources: [GuestDragSource]) {
        for case .promise(let landing) in sources {
            landing.settle(.failure(WireError(.itemRepresentationUnavailable, debugDetail: "the drag ended")))
        }
    }

    /// The tree `request` pulls: the file or folder of its item, waiting for a
    /// called-in promise's source to write it.
    func content(_ request: PullRequest) -> Result<ItemContent, WireError> {
        let source = offers.withLock { offers -> GuestDragSource? in
            guard let sources = offers[request.token], sources.indices.contains(Int(request.item)) else { return nil }
            return sources[Int(request.item)]
        }
        switch source {
        case .file(let url)?: return .success(Self.tree(url))
        case .promise(let landing)?: return landing.wait().map(Self.tree)
        case .uncalledPromise?, nil:
            return .failure(WireError(.itemRepresentationUnavailable, debugDetail: "no such dragged item is served"))
        }
    }

    private static func tree(_ url: URL) -> ItemContent {
        .tree(path: url.path)
    }
}

// MARK: - Which drags go out

/// One item of a guest drag, under ``GuestDraggedItems``' rule.
enum GuestDragItem: Equatable, Sendable {
    /// A plain file URL, of a file or a folder.
    case file(URL)
    /// A file promise, by the type its source promised.
    case promise(uti: String)

    /// Whether the item is a promise of a type conforming to
    /// `public.directory`, which lands as a folder.
    var isDirectoryPromise: Bool {
        guard case .promise(let uti) = self else { return false }
        return UTType(uti)?.conforms(to: .directory) ?? false
    }

    /// The file URL of a plain file item.
    var fileURL: URL? {
        guard case .file(let url) = self else { return nil }
        return url
    }
}

/// The one rule for which drags this guest can hand to the host: every item a
/// plain file URL or a file promise.
///
/// An item carrying a promise is a promise, whatever file URL it also
/// carries: a Photos asset offers a promise of the original beside a URL into
/// the library's derivatives, and the promise is what the source means to
/// hand over.
@MainActor
enum GuestDraggedItems {
    private static let promiseTypes = Set(
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })

    /// The flavor a promise's item names its promised type in:
    /// `kPasteboardTypeFilePromiseContent` (HIServices `Pasteboard.h`), which
    /// `NSFilePromiseReceiver.fileTypes` reads.
    nonisolated static let promisedContentType = NSPasteboard.PasteboardType(
        "com.apple.pasteboard.promised-file-content-type")

    /// Every item, in order, or `nil` unless each one is a plain file URL or a
    /// file promise that names its promised type.
    static func items(on pasteboard: any ClipboardReadPasteboard) -> [GuestDragItem]? {
        let items = pasteboard.items
        guard !items.isEmpty else { return nil }
        var read: [GuestDragItem] = []
        for item in items {
            guard let dragItem = Self.item(item) else { return nil }
            read.append(dragItem)
        }
        return read
    }

    private static func item(_ item: any ClipboardPasteboardItemReading) -> GuestDragItem? {
        guard promiseTypes.isDisjoint(with: item.types) else {
            guard let uti = item.string(forType: promisedContentType), !uti.isEmpty else { return nil }
            return .promise(uti: uti)
        }
        guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL
        else { return nil }
        return .file(url)
    }

    /// What to offer for `items`, whose file URLs resolved into `intake`, whose
    /// promises `names` names by index and whose folders `folderSizes` sizes
    /// by index, each with what its pulls are served from; `nil` unless every
    /// file resolved and every item has a name — a drag that would arrive on
    /// the Mac short of what the user dragged stays in the guest.
    ///
    /// A promise `names` leaves out is offered under a stand-in name, and
    /// nothing serves it; a folder `folderSizes` leaves out has no estimate.
    nonisolated static func offerItems(
        _ items: [GuestDragItem], resolvedFiles intake: ClipboardPasteboardReader.FileIntake,
        promises names: [Int: (name: String, landing: GuestDragLanding)] = [:], folderSizes: [Int: Int] = [:]
    ) -> [(item: OfferedItem, source: GuestDragSource)]? {
        let fileCount = items.count { $0.fileURL != nil }
        guard intake.skipped == 0, intake.representations.count == fileCount,
            items.count <= ClipboardContent.maxOfferableRepresentations
        else { return nil }
        var files = intake.representations.makeIterator()
        var offered: [(item: OfferedItem, source: GuestDragSource)] = []
        for (index, item) in items.enumerated() {
            switch item {
            case .file(let url):
                guard let resolved = files.next() else { return nil }
                guard
                    let representation = Self.representation(
                        uti: resolved.uti, isDirectory: resolved.isDirectory, name: url.lastPathComponent,
                        size: folderSizes[index] ?? resolved.byteCount, promised: false)
                else { return nil }
                offered.append((Self.item(representation), .file(url)))
            case .promise(let uti):
                let promise = names[index]
                let stem = promise?.name ?? Self.standInName(uti: uti, isDirectory: item.isDirectoryPromise)
                guard
                    let representation = Self.representation(
                        uti: uti, isDirectory: item.isDirectoryPromise, name: stem, size: 0, promised: true)
                else { return nil }
                offered.append((Self.item(representation), promise.map { .promise($0.landing) } ?? .uncalledPromise))
            }
        }
        return offered
    }

    nonisolated private static func representation(
        uti: String, isDirectory: Bool, name: String, size: Int, promised: Bool
    ) -> Representation? {
        let named = Data(name.utf8)
        guard PathComponent.isValid(named) else { return nil }
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: uti)
        representation.storage = isDirectory ? .folder : .file
        representation.name = named
        representation.sizeEstimate = UInt64(max(size, 0))
        representation.promised = promised
        return representation
    }

    nonisolated private static func item(_ representation: Representation) -> OfferedItem {
        var item = OfferedItem()
        item.representations = [representation]
        return item
    }

    /// What a promise is offered under before it is called in: `Untitled`
    /// with its promised type's extension.
    nonisolated static func standInName(uti: String, isDirectory: Bool) -> String {
        guard !isDirectory, let pathExtension = UTType(uti)?.preferredFilenameExtension else { return "Untitled" }
        return "Untitled.\(pathExtension)"
    }
}

// MARK: - On the session peer

extension GuestDragOut {
    /// DRAG's owner, as the session peer's item router hands it events on the
    /// runtime's queue: each hops to the main queue, in order. A pull's
    /// content is served on the pull's own queue.
    nonisolated var owner: DragFeatureOwner<Void> {
        let served = served
        return DragFeatureOwner(
            items: ItemFeatureOwner(
                usable: { [weak self] peer in
                    let usable = peer != nil
                    MainActorBridge.async { self?.setUsable(usable) }
                },
                events: { [weak self] _, event in
                    guard case .offerEnded(_, .local, let token, _) = event else { return }
                    MainActorBridge.async { self?.offerEnded(token) }
                },
                content: { request, _ in served.content(request) }),
            takes: { [weak self] _, event in
                switch event {
                case .requested(let id, let token): MainActorBridge.async { self?.take(id, token: token) }
                case .control(let id, let control): MainActorBridge.async { self?.control(id, control) }
                case .cancelled(let id): MainActorBridge.async { self?.cancelled(id) }
                case .report, .ended: break
                }
            })
    }
}

/// The session peer's runtime as drag-out's connection, once the peer exists:
/// it is built from the router drag-out's owner is part of.
@MainActor
final class GuestDragOutRuntimePeer: GuestDragOutPeer {
    var peer: MacAgentPeer?

    func offerDrag(_ offer: ItemOffer, _ completion: @escaping @MainActor (WireError?) -> Void) {
        guard let peer else {
            return completion(WireError(.featureUnavailable, debugDetail: "the session peer is not up"))
        }
        peer.offerItems(offer, feature: .drag) { refusal in MainActorBridge.async { completion(refusal) } }
    }

    func withdrawDrag(_ token: Data) {
        peer?.withdrawOffer(token)
    }

    func answerTake(_ id: DragTakeID, _ answer: DragTakeAnswer) {
        peer?.answerDragTake(id, answer)
    }
}
