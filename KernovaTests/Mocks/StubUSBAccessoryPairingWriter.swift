import Foundation

@testable import Kernova

/// Stand-in for the library's pairing funnel: commits the mutation to the
/// instance's own bundle, with none of the library behind it.
///
/// `roster` is what makes `pairUSBAccessory` library-wide, the way `VMLibrary`
/// reads its own `instances`.
@MainActor
final class StubUSBAccessoryPairingWriter: USBAccessoryPairingWriting {
    weak var roster: StubVMInstanceRoster?

    /// Thrown by every later write instead of committing it.
    var writeError: (any Error)?

    init(roster: StubVMInstanceRoster? = nil) {
        self.roster = roster
    }

    func updateUSBPairings(
        _ permit: borrowing VMEditPermit, mutate: (inout USBAccessoryPairingSet) -> Void
    ) throws {
        if let writeError { throw writeError }
        try permit.bundle.commitUSBPairings(mutate)
    }

    func pairUSBAccessory(_ pairing: USBAccessoryPairing, _ permit: borrowing VMEditPermit) throws {
        for other in roster?.instances ?? []
        where other !== permit.instance && other.usbPairings.pairing(forKey: pairing.key) != nil {
            try other.activity.edit(.pairingRules) { otherPermit in
                try updateUSBPairings(otherPermit) { $0.remove(key: pairing.key) }
            }
        }
        try updateUSBPairings(permit) { $0.upsert(pairing) }
    }
}
