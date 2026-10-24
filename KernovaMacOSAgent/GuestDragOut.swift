import AppKit
import Foundation
import KernovaKit

/// Dragging files out of this guest onto the Mac, for one drop-channel
/// connection: the watcher that offers each drag carrying plain file URLs, and
/// the catcher that ends the guest's drag once the host takes it over.
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
/// Created with its connection and stopped with it. The watcher runs only while
/// ``setWatching(_:)`` says so; a take that arrives while it does not is
/// refused like any other stale take.
@MainActor
final class GuestDragOut {
    private let peer: any GuestDragOutPeer
    private let input: any GuestDragInput
    private let watcher: GuestDragWatcher
    private let catcher: GuestDragCatcher

    init(peer: any GuestDragOutPeer, system: GuestDragOutSystem) {
        let input = system.makeInput()
        self.peer = peer
        self.input = input
        watcher = GuestDragWatcher(input: input, peer: peer)
        catcher = GuestDragCatcher(peer: peer, makeSurface: system.makeCatcherSurface)
        watcher.onPressEnded = { [weak catcher] press in catcher?.pressEnded(press) }
    }

    /// Starts or stops watching for drags; idempotent either way.
    func setWatching(_ watching: Bool) {
        if watching { watcher.start() } else { watcher.stop() }
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

    /// Measures the folders of the drag the host took under `generation` and
    /// sends their sizes, unless the host is done with it by then.
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
    }

    /// Ends everything this connection's drag-out holds on screen.
    func stop() {
        watcher.stop()
        catcher.stop()
    }

    #if DEBUG
    /// Test seam: the catcher, whose drag callbacks a test delivers itself in
    /// place of a window server's.
    var catcherForTesting: GuestDragCatcher { catcher }
    #endif
}

// MARK: - Seams

/// The connection a drag goes out on: what the watcher offers and withdraws
/// through, and where the catcher reports each hand-off step.
@MainActor
protocol GuestDragOutPeer: AnyObject {
    /// Announces one drag's items to the host.
    func offer(_ content: ClipboardContent, skippedBeforeOffer: Int) -> ClipboardEndpoint.OfferOutcome

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
    /// its box showing `fileURLs`, returning `false` when there is no screen
    /// to cover.
    func show(fileURLs: [URL]) -> Bool

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

// MARK: - Which drags carry files

/// The one rule for which drags this guest can hand to the host: every item a
/// plain file URL, and none a file promise.
///
/// A promised file has no name until the destination resolves it, which can be
/// later than the Mac's drop asks for one, so a drag carrying any promise stays
/// in the guest.
@MainActor
enum GuestDraggedFiles {
    private static let promiseTypes = Set(
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })

    /// Every item's file URL, in order, or `nil` unless each item has one and
    /// none advertises a promise.
    static func fileURLs(on pasteboard: any ClipboardReadPasteboard) -> [URL]? {
        let items = pasteboard.items
        guard !items.isEmpty else { return nil }
        var urls: [URL] = []
        for item in items {
            guard promiseTypes.isDisjoint(with: item.types),
                let string = item.string(forType: .fileURL),
                let url = URL(string: string), url.isFileURL
            else { return nil }
            urls.append(url)
        }
        return urls
    }

    /// The content to offer for `urls`, or `nil` unless every one of them
    /// resolved and fits in one offer — a drag that would arrive on the Mac
    /// short of what the user dragged stays in the guest.
    nonisolated static func offerableContent(
        _ intake: ClipboardPasteboardReader.FileIntake, resolvedFrom urls: [URL]
    ) -> ClipboardContent? {
        guard intake.skipped == 0, intake.representations.count == urls.count else { return nil }
        let content = ClipboardContent(representations: intake.representations)
        guard content.cappedToOfferLimit().truncatedFrom == nil else { return nil }
        return content
    }
}
