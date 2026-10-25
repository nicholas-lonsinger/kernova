import AppKit
import Foundation
import KernovaTestSupport
import Testing

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
        /// Whether the status item can carry a callout at all.
        var canCarry = true
        private(set) var shown: [NSViewController] = []
        var events: [Event] = []
        private var tenancy = TransientStatusItemPopover.Tenancy()

        var current: TransientStatusItemPopover.Showing? { tenancy.current }

        func show(_ content: NSViewController, for duration: TimeInterval?)
            -> TransientStatusItemPopover.ShowResult
        {
            guard canCarry else {
                return .skipped(.unreachable(visible: true, onScreen: false, menuOpen: false))
            }
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

    /// A drag out whose pull is waiting on the guest to name its file's size,
    /// `elapsed` seconds in.
    private func awaitingSize(
        elapsed: TimeInterval, of id: ClipboardTransferOperationID? = nil
    ) -> ClipboardTransferReport {
        .running(
            ClipboardProgressSnapshot(
                direction: .inbound, peerName: "VM", currentItemName: nil, filesCompleted: 0,
                fileCount: 1, bytesTransferred: 0, totalBytes: 0, bytesPerSecond: nil,
                secondsRemaining: nil, gesture: .dragOut, elapsedSeconds: elapsed,
                isCancellable: true, operationID: id ?? operation, awaitsSize: true),
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

    @Test("clearing the readout leaves a newer callout that replaced it up")
    func clearingLeavesANewerCallout() throws {
        let presenter = makePresenter()
        presenter.apply(running())
        #expect(slot.current != nil)
        let notice = try #require(slot.showNotice())

        presenter.apply(.idle)

        #expect(slot.events.isEmpty)
        #expect(slot.current == notice)
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

    @Test("a callout the status item could not carry leaves the reveal for a later update")
    func aSkippedShowLeavesTheRevealUnspent() {
        let presenter = makePresenter()
        slot.canCarry = false
        presenter.apply(running(elapsed: 5))
        #expect(slot.shown.isEmpty)

        slot.canCarry = true
        presenter.apply(running(elapsed: 6))
        #expect(slot.shown.count == 1)
        #expect(slot.current != nil)
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

    @Test("a readout that waits under the elapsed floor with no further update reveals as the floor passes")
    func aWaitingReadoutRevealsAtTheFloor() async throws {
        let presenter = makePresenter()
        presenter.apply(awaitingSize(elapsed: 0.25))
        #expect(slot.shown.isEmpty)
        let revisit = try #require(clock.parked.first)
        #expect(clock.parked.count == 1)
        #expect(revisit.seconds == ClipboardProgressAutoReveal.defaultMinimumElapsedToReveal - 0.25)

        clock.advance(seconds: revisit.seconds)
        clock.release(revisit)
        await clock.completion(of: revisit)

        #expect(slot.shown.count == 1)
        #expect(slot.current != nil)
        #expect(clock.parked.isEmpty)
    }

    @Test("a revisit that runs before the floor has passed arms one more for the rest")
    func anEarlyRevisitArmsForTheRest() async throws {
        let presenter = makePresenter()
        presenter.apply(awaitingSize(elapsed: 0.25))
        let first = try #require(clock.parked.first)

        clock.advance(seconds: 0.5)
        clock.release(first)
        await clock.completion(of: first)

        #expect(slot.shown.isEmpty)
        #expect(clock.parked.map(\.seconds) == [0.25])
    }

    @Test("further updates for the waiting operation keep its one revisit")
    func updatesKeepTheOneRevisit() throws {
        let presenter = makePresenter()
        presenter.apply(awaitingSize(elapsed: 0.25))
        presenter.apply(awaitingSize(elapsed: 0.5))
        #expect(clock.parked.count == 1)
    }

    @Test("a readout that clears before the floor leaves no revisit")
    func aClearCancelsTheRevisit() async throws {
        let presenter = makePresenter()
        presenter.apply(awaitingSize(elapsed: 0.25))
        #expect(clock.parked.count == 1)

        presenter.apply(.idle)

        try await clock.parkedChanged.wait { clock.parked.isEmpty }
        #expect(slot.shown.isEmpty)
    }

    @Test("a newer operation replaces the waiting one's revisit with its own")
    func aNewerOperationReplacesTheRevisit() async throws {
        let presenter = makePresenter()
        presenter.apply(awaitingSize(elapsed: 0.25))
        let first = try #require(clock.parked.first)

        presenter.apply(awaitingSize(elapsed: 0.5, of: ClipboardTransferOperationID()))

        try await clock.parkedChanged.wait { !clock.parked.contains(first) }
        #expect(clock.parked.map(\.seconds) == [0.5])
    }

    @Test("a readout whose reveal is spent arms no revisit")
    func aSpentRevealArmsNothing() async throws {
        let presenter = makePresenter()
        slot.isDropdownOpen = true
        presenter.apply(awaitingSize(elapsed: 0.25))
        slot.isDropdownOpen = false
        presenter.apply(awaitingSize(elapsed: 0.5))

        #expect(clock.requestedSeconds.isEmpty)
        #expect(slot.shown.isEmpty)
    }

    @Test("a readout that reveals on delivery arms no revisit")
    func anEarnedRevealArmsNothing() {
        let presenter = makePresenter()
        presenter.apply(awaitingSize(elapsed: 2))
        #expect(slot.shown.count == 1)
        #expect(clock.requestedSeconds.isEmpty)
    }
}
