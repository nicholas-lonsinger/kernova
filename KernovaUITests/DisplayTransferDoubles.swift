import Foundation
import KernovaKit
import KernovaTestSupport
import Observation
import Synchronization

@testable import KernovaCore

/// A VM a display moves files through, scripted by the test.
@MainActor
@Observable
final class FakeTransferHost: VMDisplayTransferHosting {
    let id = UUID()
    var displayDropAvailability: DisplayDropAvailability = .none

    /// Answers a drop; refuses by default.
    @ObservationIgnored var onDropFiles: (_ urls: [URL], _ stagedIn: URL?) -> Bool = { _, _ in false }
    @ObservationIgnored var onDropUnreadable: () -> Void = {}

    /// The take the next `takeGuestDrag` hands out, or `nil` for no drag on
    /// offer.
    @ObservationIgnored var nextTake: (any GuestDragTaking)?
    /// How many times the display asked to take a drag over.
    @ObservationIgnored private(set) var takeRequests = 0
    /// How many presses the display reported.
    @ObservationIgnored private(set) var pressCount = 0

    func sendDroppedFilesToGuest(_ urls: [URL], stagedIn stagingDirectory: URL?) -> Bool {
        onDropFiles(urls, stagingDirectory)
    }

    func reportUnreadableDropToGuest() { onDropUnreadable() }

    func displayPressBegan() { pressCount += 1 }

    func takeGuestDrag(display: any GuestDragDisplay) -> (any GuestDragTaking)? {
        takeRequests += 1
        defer { nextTake = nil }
        return nextTake
    }
}

/// A take that records what the display tells it and acts on the display only
/// as the test scripts.
@MainActor
final class FakeTake: GuestDragTaking {
    enum Event: Equatable {
        case withheldDrag
        case withheldMouseUp
        case pointerReturned
        case displayAbandoned
        case hostSessionMoved
        case hostSessionOver(CGPoint)
        case hostSessionLeft
        case hostSessionDropped(CGPoint)
        case hostSessionEnded(dropped: Bool)
    }

    nonisolated let generation: UInt64 = 1
    nonisolated let items: [ClipboardDraggedItem]
    private(set) var events: [Event] = []

    /// Runs on each withheld drag, so a test can answer as a take would.
    var onWithheldDrag: () -> Void = {}
    /// Runs on the withheld mouse-up.
    var onWithheldMouseUp: () -> Void = {}
    /// Runs when a withheld drag comes back inside the display.
    var onPointerReturned: () -> Void = {}
    /// Whether the take carries the Mac session over a display, so a drop
    /// there goes to the guest.
    var carriesOverDisplay = false
    /// Set as a take sets it: by the session coming over a display that
    /// carries it, and leaving it.
    var sessionOverDisplay = false {
        didSet {
            if sessionOverDisplay != oldValue { sessionOverDisplayChanged?(sessionOverDisplay) }
        }
    }
    var sessionOverDisplayChanged: (@MainActor (Bool) -> Void)?

    /// Every write asked for, by item index and destination.
    nonisolated let writes = Mutex<[(index: Int, destination: URL)]>([])
    /// What a write throws, or `nil` to succeed.
    nonisolated let writeError = Mutex<(any Error & Sendable)?>(nil)

    init(items: [ClipboardDraggedItem]) {
        self.items = items
    }

    func withheldDrag() {
        events.append(.withheldDrag)
        onWithheldDrag()
    }

    func withheldMouseUp() {
        events.append(.withheldMouseUp)
        onWithheldMouseUp()
    }

    func pointerReturned() {
        events.append(.pointerReturned)
        onPointerReturned()
    }

    func displayAbandoned() { events.append(.displayAbandoned) }

    func hostSessionMoved() { events.append(.hostSessionMoved) }

    func hostSession(over display: any GuestDragDisplay, at point: CGPoint) -> Bool {
        events.append(.hostSessionOver(point))
        if carriesOverDisplay { sessionOverDisplay = true }
        return carriesOverDisplay
    }

    func hostSessionLeft(_ display: any GuestDragDisplay) {
        events.append(.hostSessionLeft)
        sessionOverDisplay = false
    }

    func hostSessionDropped(on display: any GuestDragDisplay, at point: CGPoint) -> Bool {
        events.append(.hostSessionDropped(point))
        return carriesOverDisplay
    }

    func hostSessionEnded(dropped: Bool) { events.append(.hostSessionEnded(dropped: dropped)) }

    nonisolated func writeItem(at index: Int, to destination: URL) throws {
        writes.withLock { $0.append((index, destination)) }
        if let error = writeError.withLock({ $0 }) { throw error }
    }
}

extension ClipboardDraggedItem {
    /// A dragged item as the guest would declare it.
    static func declared(
        _ filename: String, uti: String = "public.data", isDirectory: Bool = false,
        byteCount: UInt64 = 1, at repIndex: Int = 0
    ) -> ClipboardDraggedItem {
        ClipboardDraggedItem(
            repIndex: repIndex,
            declared: RepInfo(
                uti: uti, byteCount: byteCount, filename: filename, isInline: false,
                isDirectory: isDirectory
            ).wire)
    }
}
