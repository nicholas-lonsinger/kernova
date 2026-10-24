import AppKit
import Foundation
import KernovaKit
import UniformTypeIdentifiers

/// Dragging files out of this guest onto the Mac, for one drop-channel
/// connection: the watcher that offers each drag of plain file URLs and file
/// promises, the catcher that ends the guest's drag once the host takes it
/// over, and the promises the catcher calls in.
///
/// The host takes a drag over with `DragTake` once the pointer leaves the VM
/// display with the button held, and may inject a button release onto the
/// catcher only after it reports `targeted` — an injected release is a real
/// drop under the guest pointer, so every step before that one either
/// succeeds or reports `failed`, and the host then hands the press back to the
/// guest untouched. While the host's drag session is back over the VM display,
/// `DragCatcher` stands the catcher down and the host drives the guest drag
/// to the user's own drop.
///
/// An offer lists no folder's contents — a drag that never leaves the display
/// reads nothing inside the folders it carries — so the folders' sizes go to
/// the host in `DragSizes` once it takes the drag, measured off the main actor
/// while the catcher's steps run.
///
/// A promise has no file until a destination calls it in, so the host asks
/// with `DragResolve` once a Mac destination wants its name; the catcher then
/// calls the drag's promises in at the drop the host releases onto it, and
/// only that drop — a drag nobody dropped on the Mac exports nothing.
///
/// Created with its connection and stopped with it. The watcher runs only while
/// ``setOffering(_:)`` says so; a take that arrives while it does not is
/// refused like any other stale take.
@MainActor
final class GuestDragOut {
    private let peer: any GuestDragOutPeer
    private let input: any GuestDragInput
    private let watcher: GuestDragWatcher
    private let catcher: GuestDragCatcher
    private let promises: GuestDragPromises

    init(peer: any GuestDragOutPeer, system: GuestDragOutSystem, stagingRoot: ProcessStagingRoot) {
        let input = system.makeInput()
        self.peer = peer
        self.input = input
        watcher = GuestDragWatcher(input: input, peer: peer)
        promises = GuestDragPromises(peer: peer, input: input, stagingRoot: stagingRoot)
        catcher = GuestDragCatcher(peer: peer, promises: promises, makeSurface: system.makeCatcherSurface)
        watcher.onPressEnded = { [weak catcher] press in catcher?.pressEnded(press) }
    }

    /// Watches for drags to offer the host, of what `support` says it takes,
    /// or stops watching; idempotent either way.
    func setOffering(_ support: HostDragOutSupport) {
        switch support {
        case .none:
            watcher.stop()
        case .files, .filesAndPromises:
            watcher.offersPromises = support == .filesAndPromises
            watcher.start()
        }
    }

    /// The host asked for the drag it holds under `generation`.
    func take(generation: UInt64) {
        switch watcher.claim(generation: generation) {
        case .success(let claim):
            catcher.arm(claim)
            sendFolderSizes(of: generation)
        case .failure(let refusal):
            catcher.refuse(generation: generation, code: .dragTakeStale, message: refusal.message)
        }
    }

    /// The host's Mac session carrying the drag under `generation` left this
    /// VM's display (`shown`), or came back over it.
    func setCatcherShown(_ shown: Bool, generation: UInt64) {
        catcher.setShown(shown, generation: generation)
    }

    /// A Mac destination wants the names of the promised items of the drag the
    /// host took under `generation`.
    func resolve(generation: UInt64) {
        catcher.resolve(generation: generation)
    }

    /// Measures the folders of the drag the host took under `generation` and
    /// sends their sizes, unless the host is done with it by then.
    ///
    /// Every folder goes in the one `DragSizes`: the host pulls no folder until
    /// a `DragSizes` sizes it.
    private func sendFolderSizes(of generation: UInt64) {
        guard let folders = peer.outboundContent(generation: generation)?.directorySources,
            !folders.isEmpty
        else { return }
        input.measureFolders(folders) { [weak self] sizes in
            _ = self?.peer.sendDragSizes(generation: generation, folderByteCounts: sizes)
        }
    }

    /// The host is done with the drag under `generation`; the endpoint has
    /// already retired it.
    func complete(generation: UInt64) {
        watcher.forget(generation: generation)
        catcher.complete(generation: generation)
        promises.complete(generation: generation)
    }

    /// Ends everything this connection's drag-out holds on screen, and lets go
    /// of its called-in promises once their reads settle.
    func stop() {
        watcher.stop()
        catcher.stop()
        promises.stop()
    }

    #if DEBUG
    /// Test seam: the catcher, whose drag callbacks a test delivers itself in
    /// place of a window server's.
    var catcherForTesting: GuestDragCatcher { catcher }
    #endif
}

// MARK: - Seams

/// The connection a drag goes out on: what the watcher offers and withdraws
/// through, where the catcher reports each hand-off step, and where called-in
/// promises land.
@MainActor
protocol GuestDragOutPeer: AnyObject {
    /// Announces one drag's items, files and promises, to the host.
    func offerDrag(_ items: [ClipboardDragOutItem]) -> ClipboardEndpoint.OfferOutcome

    /// Withdraws the drag under `generation`; `false` when none was live.
    func withdraw(generation: UInt64) -> Bool

    /// Reports one step of handing the drag under `generation` to the host.
    func sendDragHandOff(generation: UInt64, step: ClipboardDragHandOffStep)

    /// What the drag under `generation` offered, or `nil` once it is retired.
    func outboundContent(generation: UInt64) -> ClipboardContent?

    /// Records and sends the measured sizes of the folders in the drag under
    /// `generation`, keyed by index; `false` when it is retired or the send
    /// failed.
    func sendDragSizes(generation: UInt64, folderByteCounts: [Int: Int]) -> Bool

    /// Sends the names the promised items of the drag under `generation` took
    /// when they were called in, keyed by index.
    func sendDragNames(generation: UInt64, filenames: [Int: String]) -> Bool

    /// Puts the file a promise wrote in place of its placeholder and sends the
    /// host its size.
    func resolvePromisedDragItem(generation: UInt64, repIndex: Int, fileURL: URL, byteCount: Int) -> Bool

    /// Tells the host the promises among `repIndices` will never be written.
    func markPromisedDragItemsUnavailable(generation: UInt64, repIndices: [Int]) -> Bool
}

extension ClipboardEndpoint: GuestDragOutPeer {}

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

    /// Measures each of `folders`, keyed by index, off the main actor — a walk
    /// of its whole tree — and hands the sizes back on it under the same keys.
    func measureFolders(
        _ folders: [Int: URL], then completion: @escaping @MainActor @Sendable ([Int: Int]) -> Void)
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
    /// Builds the watcher's input, once per connection.
    var makeInput: @MainActor @Sendable () -> any GuestDragInput

    /// Builds the catcher's surface the first time a take arms it, delivering
    /// its drag callbacks to the catcher it is given.
    var makeCatcherSurface: @MainActor @Sendable (GuestDragCatcher) -> any GuestDragCatcherSurface

    /// The guest's own event stream, drag pasteboard and screen.
    static let live = GuestDragOutSystem(
        makeInput: { SystemGuestDragInput() },
        makeCatcherSurface: { GuestDragCatcherPanel(catcher: $0) })
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

    /// Every item, in order, or `nil` unless each one is a plain file URL or —
    /// when `acceptingPromises` — a file promise that names its promised type.
    static func items(
        on pasteboard: any ClipboardReadPasteboard, acceptingPromises: Bool
    ) -> [GuestDragItem]? {
        let items = pasteboard.items
        guard !items.isEmpty else { return nil }
        var read: [GuestDragItem] = []
        for item in items {
            guard let dragItem = Self.item(item, acceptingPromises: acceptingPromises) else { return nil }
            read.append(dragItem)
        }
        return read
    }

    private static func item(
        _ item: any ClipboardPasteboardItemReading, acceptingPromises: Bool
    ) -> GuestDragItem? {
        guard promiseTypes.isDisjoint(with: item.types) else {
            guard acceptingPromises, let uti = item.string(forType: promisedContentType), !uti.isEmpty
            else { return nil }
            return .promise(uti: uti)
        }
        guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL
        else { return nil }
        return .file(url)
    }

    /// What to offer for `items`, whose file URLs resolved into `intake`, or
    /// `nil` unless every file resolved and the whole drag fits in one offer —
    /// a drag that would arrive on the Mac short of what the user dragged
    /// stays in the guest.
    nonisolated static func offerItems(
        _ items: [GuestDragItem], resolvedFiles intake: ClipboardPasteboardReader.FileIntake
    ) -> [ClipboardDragOutItem]? {
        let fileCount = items.count { $0.fileURL != nil }
        guard intake.skipped == 0, intake.representations.count == fileCount,
            items.count <= ClipboardContent.maxOfferableRepresentations
        else { return nil }
        var files = intake.representations.makeIterator()
        var offered: [ClipboardDragOutItem] = []
        for item in items {
            switch item {
            case .file:
                guard let representation = files.next() else { return nil }
                offered.append(.file(representation))
            case .promise(let uti):
                offered.append(.promise(uti: uti, isDirectory: item.isDirectoryPromise))
            }
        }
        return offered
    }
}
