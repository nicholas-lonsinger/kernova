import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport

/// The guest's event stream and drag pasteboard, driven by hand: a test
/// presses and releases the button, fires the press timer, and decides when
/// each off-main resolve comes back.
@MainActor
final class FakeGuestDragInput: GuestDragInput {
    let pasteboard = FakeReadPasteboard()
    var dragPasteboard: any ClipboardReadPasteboard { pasteboard }
    var isPrimaryButtonHeld = false

    /// Fires on every registration, cancellation and queued resolve.
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
            resolve.completion(intake ?? ClipboardPasteboardReader.resolve(filesAt: resolve.urls))
        }
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
            MainActorBridge.async { completion(ClipboardPasteboardReader.resolve(filesAt: urls)) }
        } else {
            pendingResolves.append((urls, completion))
        }
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
    }

    private(set) var events: [Event] = []
    private var nextGeneration: UInt64 = 1

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
        return .sent(generation: generation)
    }

    func withdraw(generation: UInt64) -> Bool {
        events.append(.withdrew(generation: generation))
        return true
    }

    func sendDragHandOff(generation: UInt64, step: ClipboardDragHandOffStep) {
        events.append(.handOff(generation: generation, step: step))
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
