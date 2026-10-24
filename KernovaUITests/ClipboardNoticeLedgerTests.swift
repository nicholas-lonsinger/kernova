import Foundation
import Testing

@testable import KernovaUI

/// Unit tests for `ClipboardNoticeLedger` — which surface the menu-bar status
/// item presents a VM's refusal on, once.
@Suite("ClipboardNoticeLedger", .caseScoped)
struct ClipboardNoticeLedgerTests {
    private let vm = UUID()
    private let raised = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("a refusal raised with the dropdown closed is noticed once")
    func closedDropdownNoticesOnce() {
        var ledger = ClipboardNoticeLedger()

        #expect(ledger.route(raised, for: vm, dropdownIsOpen: false) == .notice)
        #expect(ledger.route(raised, for: vm, dropdownIsOpen: false) == .presented)
        #expect(ledger.route(raised, for: vm, dropdownIsOpen: true) == .presented)
    }

    @Test("a refusal raised into a dropdown the user opened is its line, never also a notice")
    func openDropdownCarriesTheLine() {
        var ledger = ClipboardNoticeLedger()

        #expect(ledger.route(raised, for: vm, dropdownIsOpen: true) == .dropdownLine)

        // The user closing that dropdown does not replay it as a popover.
        #expect(ledger.route(raised, for: vm, dropdownIsOpen: false) == .presented)
    }

    @Test("a later refusal of the same kind is news, and each VM's refusals are its own")
    func laterRefusalAndOtherVMsAreNews() {
        var ledger = ClipboardNoticeLedger()
        #expect(ledger.route(raised, for: vm, dropdownIsOpen: false) == .notice)

        #expect(ledger.route(raised.addingTimeInterval(1), for: vm, dropdownIsOpen: false) == .notice)
        #expect(ledger.route(raised, for: UUID(), dropdownIsOpen: false) == .notice)
    }
}
