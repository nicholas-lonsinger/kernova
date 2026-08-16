import AppKit
import Testing

@testable import KernovaKit

/// Unit tests for the Cancel affordance on the dropdown's transfer readout.
@Suite("ClipboardProgressMenuItemView")
@MainActor
struct ClipboardProgressMenuItemViewTests {
    private func makeSnapshot(isCancellable: Bool) -> ClipboardProgressSnapshot {
        ClipboardProgressSnapshot(
            direction: .outbound, peerName: "VM", currentItemName: "a.bin", filesCompleted: 0,
            fileCount: 1, bytesTransferred: 10, totalBytes: 100, bytesPerSecond: nil,
            secondsRemaining: nil, gesture: .paste, elapsedSeconds: 1,
            isCancellable: isCancellable)
    }

    @Test("the button is hidden until a cancel handler is installed")
    func hidesTheButtonWithoutAHandler() {
        let view = ClipboardProgressMenuItemView()
        #expect(view.cancelButtonForTesting.isHidden)

        view.onCancel = {}
        #expect(!view.cancelButtonForTesting.isHidden)

        view.onCancel = nil
        #expect(view.cancelButtonForTesting.isHidden)
    }

    @Test("clicking the button runs the handler installed at click time")
    func clickRunsTheCurrentHandler() {
        let view = ClipboardProgressMenuItemView()
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

    @Test("the item is tall enough for the row that carries the button")
    func measuresWithTheButtonInPlace() {
        // `NSMenu` takes a custom item's height from the frame once, so the
        // measurement has to include a button the first cancellable readout will
        // reveal.
        let view = ClipboardProgressMenuItemView()
        let withoutButton = view.fittingSize.height
        view.onCancel = {}
        view.layoutSubtreeIfNeeded()

        #expect(view.frame.height >= withoutButton)
        #expect(view.frame.height >= view.cancelButtonForTesting.fittingSize.height)
    }

    @Test("applying a snapshot renders it without disturbing the handler")
    func applyKeepsTheHandler() {
        let view = ClipboardProgressMenuItemView()
        view.onCancel = {}
        view.apply(makeSnapshot(isCancellable: true))

        #expect(!view.cancelButtonForTesting.isHidden)
        #expect(view.accessibilityLabel()?.isEmpty == false)
    }
}
