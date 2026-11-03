import Foundation
import KernovaKit
import KernovaTestSupport
import Observation
import Synchronization
import UniformTypeIdentifiers

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
        case hostSessionEnded(dropped: Bool)
    }

    nonisolated let items: [DraggedOutItem]
    private(set) var events: [Event] = []

    /// Runs on each withheld drag, so a test can answer as a take would.
    var onWithheldDrag: () -> Void = {}
    /// Runs on the withheld mouse-up.
    var onWithheldMouseUp: () -> Void = {}
    /// Runs when a withheld drag comes back inside the display.
    var onPointerReturned: () -> Void = {}
    /// Runs when the Mac session ends.
    var onHostSessionEnded: () -> Void = {}

    /// Every write asked for, by item index and destination.
    nonisolated let writes = Mutex<[(index: Int, destination: URL)]>([])
    /// What a write fails with, or `nil` to succeed.
    nonisolated let writeError = Mutex<(any Error & Sendable)?>(nil)

    init(items: [DraggedOutItem]) {
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

    func hostSessionEnded(dropped: Bool) {
        events.append(.hostSessionEnded(dropped: dropped))
        onHostSessionEnded()
    }

    nonisolated func filename(forItemAt index: Int) -> String {
        items[index].filename
    }

    nonisolated func writeItem(
        at index: Int, to destination: URL, completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        writes.withLock { $0.append((index, destination)) }
        completion(writeError.withLock { $0 })
    }
}

extension DraggedOutItem {
    /// A dragged item as the guest would offer it.
    static func declared(_ filename: String, type: UTType = .data, isDirectory: Bool = false) -> DraggedOutItem {
        DraggedOutItem(name: Data(filename.utf8), type: type, isDirectory: isDirectory)
    }
}
