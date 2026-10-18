import AppKit
import Foundation
import KernovaKit

/// Dragging files out of this guest onto the Mac, for one drop-channel
/// connection: the watcher that offers each drag carrying plain file URLs, and
/// the catcher that ends the guest's drag once the host takes it over.
///
/// The host takes a drag over with `DragTake` once the pointer leaves the VM
/// display with the button held, and may inject a button release into the
/// guest only after the catcher reports `targeted` — an injected release is a
/// real drop under the guest pointer, so every step before that one either
/// succeeds or reports `failed`, and the host then hands the press back to the
/// guest untouched.
///
/// Created with its connection and stopped with it. The watcher runs only while
/// ``setWatching(_:)`` says so; a take that arrives while it does not is
/// refused like any other stale take.
@MainActor
final class GuestDragOut {
    private let watcher: GuestDragWatcher
    private let catcher: GuestDragCatcher
    private let grants: GuestDropGrants

    init(peer: any GuestDragOutPeer, system: GuestDragOutSystem) {
        watcher = GuestDragWatcher(input: system.makeInput(), peer: peer)
        grants = GuestDropGrants(scope: system.makeDropAccess())
        catcher = GuestDragCatcher(
            peer: peer, grants: grants, makeSurface: system.makeCatcherSurface)
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
        case .failure(let refusal):
            catcher.refuse(generation: generation, code: .dragTakeStale, message: refusal.message)
        }
    }

    /// The host is done with the drag under `generation`; the endpoint has
    /// already retired it, so nothing pulls its files again.
    ///
    /// The host's `DragComplete` is the one settle a caught drag has on a live
    /// connection: the watcher never withdraws a claimed offer, and a Cancel
    /// on its readout sends a `DragRelease` the host answers with this.
    func complete(generation: UInt64) {
        watcher.forget(generation: generation)
        catcher.complete(generation: generation)
        grants.release(generation: generation)
    }

    /// Ends everything this connection's drag-out holds, on screen and on the
    /// dropped files.
    func stop() {
        watcher.stop()
        catcher.stop()
        grants.releaseAll()
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
    /// and a walk of every folder — and hands the result back on it.
    func resolveFiles(
        _ urls: [URL],
        then completion: @escaping @MainActor @Sendable (ClipboardPasteboardReader.FileIntake) -> Void)
}

/// The on-screen window that receives the guest's drag once the host has taken
/// it over.
@MainActor
protocol GuestDragCatcherSurface: AnyObject {
    /// Orders the surface front over the whole screen under the pointer,
    /// returning `false` when there is no screen to cover.
    func show() -> Bool

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

    /// Builds what starts and stops access to dropped files, once per
    /// connection.
    var makeDropAccess: @MainActor @Sendable () -> any GuestDropAccessScope

    /// The guest's own event stream, drag pasteboard, screen and file access.
    static let live = GuestDragOutSystem(
        makeInput: { SystemGuestDragInput() },
        makeCatcherSurface: { GuestDragCatcherPanel(catcher: $0) },
        makeDropAccess: { SecurityScopedDropAccess() })
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

    /// The file URLs a drop delivers, read as the URL objects that carry the
    /// drop's access to them — never rebuilt from a string, which carries none.
    static func droppedFileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return objects?.compactMap { $0 as? URL } ?? []
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
