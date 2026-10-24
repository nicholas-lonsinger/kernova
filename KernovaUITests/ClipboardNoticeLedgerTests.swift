import Foundation
import Testing

@testable import KernovaUI

/// Unit tests for `ClipboardNoticeLedger` — which surface the menu-bar status
/// item presents a VM's refusal on, once.
@Suite("ClipboardNoticeLedger", .caseScoped)
struct ClipboardNoticeLedgerTests {
    private let vm = UUID()
    private let raised = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("a refusal raised as the readout's own dropdown closes waits for the close, then is noticed once")
    func closingDropdownDefersTheNotice() {
        var ledger = ClipboardNoticeLedger()

        // Every pass while the dropdown is still closing leaves it unpresented.
        #expect(ledger.route(raised, for: vm, dropdown: .closing) == .afterClose)
        #expect(ledger.route(raised, for: vm, dropdown: .closing) == .afterClose)

        // The pass after the close presents it, and no later pass again.
        #expect(ledger.route(raised, for: vm, dropdown: .closed) == .notice)
        #expect(ledger.route(raised, for: vm, dropdown: .closed) == .presented)
        #expect(ledger.route(raised, for: vm, dropdown: .open) == .presented)
    }

    @Test("a refusal raised into a dropdown the user opened is its line, never also a notice")
    func openDropdownCarriesTheLine() {
        var ledger = ClipboardNoticeLedger()

        #expect(ledger.route(raised, for: vm, dropdown: .open) == .dropdownLine)

        // The user closing that dropdown does not replay it as a popover.
        #expect(ledger.route(raised, for: vm, dropdown: .closed) == .presented)
    }

    @Test("a later refusal of the same kind is news, and each VM's refusals are its own")
    func laterRefusalAndOtherVMsAreNews() {
        var ledger = ClipboardNoticeLedger()
        #expect(ledger.route(raised, for: vm, dropdown: .closed) == .notice)

        #expect(ledger.route(raised.addingTimeInterval(1), for: vm, dropdown: .closed) == .notice)
        #expect(ledger.route(raised, for: UUID(), dropdown: .closed) == .notice)
    }
}
