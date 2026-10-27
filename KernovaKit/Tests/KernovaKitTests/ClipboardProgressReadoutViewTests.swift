import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaAppKitShared
@testable import KernovaKit

/// Unit tests for the transfer readout the status item's dropdown and callout
/// both show.
@Suite("ClipboardProgressReadoutView", .caseScoped)
@MainActor
struct ClipboardProgressReadoutViewTests {
    private func makeSnapshot(isCancellable: Bool, pendingBehind: Int = 0)
        -> ClipboardProgressSnapshot
    {
        ClipboardProgressSnapshot(
            direction: .outbound, peerName: "VM", currentItemName: "a.bin", filesCompleted: 0,
            fileCount: 1, bytesTransferred: 10, totalBytes: 100, bytesPerSecond: nil,
            secondsRemaining: nil, gesture: .paste, elapsedSeconds: 1,
            isCancellable: isCancellable, pendingBehind: pendingBehind)
    }

    @Test("the button is hidden until a cancel handler is installed")
    func hidesTheButtonWithoutAHandler() {
        let view = ClipboardProgressReadoutView(surface: .dropdownItem)
        #expect(view.cancelButtonForTesting.isHidden)

        view.onCancel = {}
        #expect(!view.cancelButtonForTesting.isHidden)

        view.onCancel = nil
        #expect(view.cancelButtonForTesting.isHidden)
    }

    @Test("clicking the button runs the handler installed at click time")
    func clickRunsTheCurrentHandler() {
        let view = ClipboardProgressReadoutView(surface: .dropdownItem)
        var first = 0
        var second = 0
        view.onCancel = { first += 1 }
        view.cancelButtonForTesting.performClick(nil)
        #expect(first == 1)

        // Replaced between two operations: the click must stop the live one.
        view.onCancel = { second += 1 }
        view.cancelButtonForTesting.performClick(nil)
        #expect(first == 1)
        #expect(second == 1)
    }

    @Test(
        "the readout is tall enough for the row that carries the button",
        arguments: [ClipboardProgressReadoutView.Surface.dropdownItem, .callout])
    func measuresWithTheButtonInPlace(surface: ClipboardProgressReadoutView.Surface) {
        // Both surfaces take the height from the frame once, so the measurement
        // has to include a button the first cancellable readout will reveal.
        let view = ClipboardProgressReadoutView(surface: surface)
        let withoutButton = view.fittingSize.height
        view.onCancel = {}
        view.layoutSubtreeIfNeeded()

        #expect(view.frame.height >= withoutButton)
        #expect(view.frame.height >= view.cancelButtonForTesting.fittingSize.height)
    }

    @Test("applying a snapshot renders it without disturbing the handler")
    func applyKeepsTheHandler() {
        let view = ClipboardProgressReadoutView(surface: .dropdownItem)
        view.onCancel = {}
        view.apply(makeSnapshot(isCancellable: true))

        #expect(!view.cancelButtonForTesting.isHidden)
        #expect(view.accessibilityLabel()?.isEmpty == false)
    }

    @Test(
        "the readout says what is queued behind it, and costs no height to say so",
        arguments: [ClipboardProgressReadoutView.Surface.dropdownItem, .callout])
    func rendersWhatIsPendingBehindTheReadout(surface: ClipboardProgressReadoutView.Surface) {
        let view = ClipboardProgressReadoutView(surface: surface)
        let height = view.frame.height

        view.apply(makeSnapshot(isCancellable: true))
        #expect(view.accessibilityLabel()?.contains("pending") == false)

        view.apply(makeSnapshot(isCancellable: true, pendingBehind: 2))
        view.layoutSubtreeIfNeeded()

        #expect(view.accessibilityLabel()?.contains("2 more transfers pending") == true)
        // The surface takes this height once, so the line has to share a row.
        #expect(view.frame.height == height)
    }

    @Test("the bar shows a snapshot applied while the view has no window")
    func barShowsASnapshotAppliedOffScreen() {
        // The status item's dropdown applies snapshots before it opens.
        let view = ClipboardProgressReadoutView(surface: .dropdownItem)
        #expect(view.window == nil)

        view.apply(makeSnapshot(isCancellable: true))

        #expect(view.barFractionForTesting == 0.1)
    }

    @Test("a readout awaiting its total shows no fraction, and a sized one shows its fraction again")
    func awaitedSizeShowsNoFraction() {
        let view = ClipboardProgressReadoutView(surface: .dropdownItem)
        view.apply(
            ClipboardProgressSnapshot(
                direction: .inbound, peerName: "VM", currentItemName: "Home", filesCompleted: 0,
                fileCount: 1, bytesTransferred: 0, totalBytes: 0, bytesPerSecond: nil,
                secondsRemaining: nil, gesture: .dragOut, elapsedSeconds: 1, awaitsSize: true))
        #expect(view.barIsIndeterminateForTesting)
        #expect(view.byteProgressForTesting == "Waiting for the total size")

        view.apply(makeSnapshot(isCancellable: true))
        #expect(!view.barIsIndeterminateForTesting)
        #expect(view.barFractionForTesting == 0.1)
    }

    @Test("the callout readout is as wide as every callout")
    func calloutTakesTheCalloutWidth() {
        #expect(ClipboardProgressReadoutView(surface: .callout).frame.width == CalloutStyle.width)
    }

    @Test("Cancel acts on the click that also activates its app")
    func cancelTakesTheFirstClick() {
        // The guest agent is never the active app, so a Cancel that only
        // activated it would let the transfer run on.
        let view = ClipboardProgressReadoutView(surface: .callout)
        #expect(view.cancelButtonForTesting.acceptsFirstMouse(for: nil))
    }
}
