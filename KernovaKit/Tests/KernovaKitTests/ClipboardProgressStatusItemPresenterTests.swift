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

        func show(_ content: NSViewController, as lifetime: CalloutLifetime)
            -> TransientStatusItemPopover.ShowResult
        {
            guard let showing = tenancy.begin(lifetime) else {
                return .skipped(.outranked)
            }
            shown.append(content)
            return .shown(showing)
        }

        func dismiss(_ showing: TransientStatusItemPopover.Showing) -> Bool {
            guard tenancy.end(showing) else { return false }
            events.append(.dismissed(showing))
            return true
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
}
