import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaAppKitShared
@testable import KernovaKit

/// Unit tests for how the presenter drives the status item's callout slot.
@Suite("ClipboardProgressStatusItemPresenter", .caseScoped)
@MainActor
struct ClipboardProgressStatusItemPresenterTests {
    /// What the slot and the presenter's Cancel did, in order.
    enum Event: Equatable {
        case dismissed(TransientStatusItemPopover.Showing)
        case cancelled(ClipboardTransferOperationID)
    }

    /// A slot holding showings by the real tenancy rules, with no status item.
    final class RecordingSlot: StatusItemCalloutSlot {
        var isDropdownOpen = false
        private(set) var shown: [NSViewController] = []
        var events: [Event] = []
        private var tenancy = TransientStatusItemPopover.Tenancy()

        var current: TransientStatusItemPopover.Showing? { tenancy.current }

        func show(_ content: NSViewController, for duration: TimeInterval?)
            -> TransientStatusItemPopover.ShowResult
        {
            guard let showing = tenancy.begin(timed: duration != nil) else {
                return .skipped(.timedCalloutUp)
            }
            shown.append(content)
            return .shown(showing)
        }

        func dismiss(_ showing: TransientStatusItemPopover.Showing) -> Bool {
            guard tenancy.end(showing) else { return false }
            events.append(.dismissed(showing))
            return true
        }

        /// Puts a timed callout up — a notice — as another owner would.
        func showNotice() -> TransientStatusItemPopover.Showing? {
            guard case .shown(let showing) = show(NSViewController(), for: 6) else { return nil }
            return showing
        }

        /// Ends a showing the way its own timer would.
        func expire(_ showing: TransientStatusItemPopover.Showing) {
            _ = tenancy.end(showing)
        }
    }

    private let slot = RecordingSlot()
    private let operation = ClipboardTransferOperationID()

    private let clock = GatedEngineClock()

    private func makePresenter() -> ClipboardProgressStatusItemPresenter {
        ClipboardProgressStatusItemPresenter(
            menu: NSMenu(), slot: slot, onCancel: { [slot] id in slot.events.append(.cancelled(id)) },
            clock: clock)
    }

    /// A drag out that does not know its bytes, `elapsed` seconds in.
    private func sizeUnknown(
        elapsed: TimeInterval, of id: ClipboardTransferOperationID? = nil
    ) -> ClipboardTransferReport {
        .running(
            ClipboardProgressSnapshot(
                direction: .inbound, peerName: "VM", currentItemName: nil, filesCompleted: 0,
                fileCount: 1, bytesTransferred: 0, totalBytes: 0, bytesPerSecond: nil,
                secondsRemaining: nil, gesture: .dragOut, elapsedSeconds: elapsed,
                isCancellable: true, operationID: id ?? operation, bytesKnown: false),
            since: Date())
    }

    /// A running report that earns the reveal, for `operation`.
    private func running(elapsed: TimeInterval = 5) -> ClipboardTransferReport {
        .running(
            ClipboardProgressSnapshot(
                direction: .outbound, peerName: "VM", currentItemName: nil, filesCompleted: 0,
                fileCount: 1, bytesTransferred: 100, totalBytes: 1_000, bytesPerSecond: 100,
                secondsRemaining: 10, gesture: .peerPaste, elapsedSeconds: elapsed,
                isCancellable: true, operationID: operation),
            since: Date())
    }

    @Test("clearing the readout closes its own callout")
    func clearingClosesTheCallout() throws {
        let presenter = makePresenter()
        presenter.apply(running())
        let readout = try #require(slot.current)

        presenter.apply(.idle)

        #expect(slot.events == [.dismissed(readout)])
        #expect(slot.current == nil)
    }

    @Test("Cancel in the callout closes it, then cancels the operation it was rendered for")
    func cancelClosesThenCancels() throws {
        let presenter = makePresenter()
        presenter.apply(running())
        let readout = try #require(slot.current)
        let content = try #require(slot.shown.last)
        let view = try #require(content.view as? ClipboardProgressReadoutView)

        view.cancelButtonForTesting.performClick(nil)

        #expect(slot.events == [.dismissed(readout), .cancelled(operation)])
    }

    @Test("a timed callout already up holds the reveal back until its time is up")
    func aTimedCalloutHoldsTheRevealBack() throws {
        let presenter = makePresenter()
        let notice = try #require(slot.showNotice())

        presenter.apply(running(elapsed: 5))
        #expect(slot.current == notice)

        slot.expire(notice)
        presenter.apply(running(elapsed: 6))
        #expect(slot.current != nil)
        #expect(slot.current != notice)
    }

    @Test("a revisit that runs before the floor has passed arms one more for the rest")
    func anEarlyRevisitArmsForTheRest() async throws {
        let presenter = makePresenter()
        presenter.apply(sizeUnknown(elapsed: 0.25))
        let first = try #require(clock.parked.first)

        clock.advance(seconds: 0.5)
        clock.release(first)
        await clock.completion(of: first)

        #expect(slot.shown.isEmpty)
        #expect(clock.parked.map(\.seconds) == [0.25])
    }

    @Test("a readout that clears before the floor leaves no revisit")
    func aClearCancelsTheRevisit() async throws {
        let presenter = makePresenter()
        presenter.apply(sizeUnknown(elapsed: 0.25))
        #expect(clock.parked.count == 1)

        presenter.apply(.idle)

        try await clock.parkedChanged.wait { clock.parked.isEmpty }
        #expect(slot.shown.isEmpty)
    }

    @Test("a newer operation replaces the waiting one's revisit with its own")
    func aNewerOperationReplacesTheRevisit() async throws {
        let presenter = makePresenter()
        presenter.apply(sizeUnknown(elapsed: 0.25))
        let first = try #require(clock.parked.first)

        presenter.apply(sizeUnknown(elapsed: 0.5, of: ClipboardTransferOperationID()))

        try await clock.parkedChanged.wait { !clock.parked.contains(first) }
        #expect(clock.parked.map(\.seconds) == [0.5])
    }

    @Test("a readout whose reveal is spent arms no revisit")
    func aSpentRevealArmsNothing() async throws {
        let presenter = makePresenter()
        slot.isDropdownOpen = true
        presenter.apply(sizeUnknown(elapsed: 0.25))
        slot.isDropdownOpen = false
        presenter.apply(sizeUnknown(elapsed: 0.5))

        #expect(clock.requestedSeconds.isEmpty)
        #expect(slot.shown.isEmpty)
    }
}
