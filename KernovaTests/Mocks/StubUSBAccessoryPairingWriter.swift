import Foundation

@testable import Kernova

/// Stand-in for the library's pairing funnel: applies the mutation to the
/// instance's own mirror and records that it was asked to, with no bundle
/// behind it.
///
/// `roster` is what makes `pairUSBAccessory` library-wide, the way `VMLibrary`
/// reads its own `instances`.
@MainActor
final class StubUSBAccessoryPairingWriter: USBAccessoryPairingWriting {
    weak var roster: StubVMInstanceRoster?

    init(roster: StubVMInstanceRoster? = nil) {
        self.roster = roster
    }

    @discardableResult
    func updateUSBPairings(
        of instance: VMInstance, mutate: (inout USBAccessoryPairingSet) -> Void
    ) -> Bool {
        var new = instance.usbPairings
        mutate(&new)
        guard new != instance.usbPairings else { return true }
        instance.usbPairings = new
        return true
    }

    func pairUSBAccessory(_ pairing: USBAccessoryPairing, with instance: VMInstance) {
        for other in roster?.instances ?? [] where other !== instance {
            updateUSBPairings(of: other) { $0.remove(key: pairing.key) }
        }
        updateUSBPairings(of: instance) { $0.upsert(pairing) }
    }
}
