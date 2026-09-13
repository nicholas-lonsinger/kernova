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

    /// The VM each write named, in order.
    private(set) var writtenInstanceIDs: [UUID] = []

    /// Fails every write, for the path where a bundle cannot be written.
    var refusesWrites = false

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
        writtenInstanceIDs.append(instance.id)
        instance.usbPairings = new
        return !refusesWrites
    }

    func pairUSBAccessory(_ pairing: USBAccessoryPairing, with instance: VMInstance) {
        for other in roster?.instances ?? [] where other !== instance {
            updateUSBPairings(of: other) { $0.remove(key: pairing.key) }
        }
        updateUSBPairings(of: instance) { $0.upsert(pairing) }
    }
}
