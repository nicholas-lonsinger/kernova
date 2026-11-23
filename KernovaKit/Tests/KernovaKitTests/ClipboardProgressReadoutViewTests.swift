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
}
