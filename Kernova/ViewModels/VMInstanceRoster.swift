import Foundation

/// Read access to the set of VMs the app knows about, for the collaborators
/// ``VMLibrary`` sequences without handing them ownership of the list.
///
/// Conformers are `@Observable`, so a read reaches the observation tracking a
/// SwiftUI or AppKit surface installed — a collaborator that cached the array
/// would silently drop that dependency.
@MainActor
protocol VMInstanceRoster: AnyObject {
    var instances: [VMInstance] { get }
}

/// Write access to what a VM takes its USB accessories back from, for the same
/// collaborators.
///
/// Separate from ``VMInstanceRoster`` so that stays a pure read: a collaborator
/// that only lists VMs cannot reach a bundle write, and one that needs the
/// write reaches the library's funnel.
@MainActor
protocol USBAccessoryPairingWriting: AnyObject {
    /// Commits `mutate` to `instance`'s pairings file, throwing when the write
    /// fails and leaving the pairings as the bundle holds them.
    func updateUSBPairings(
        of instance: VMInstance, mutate: (inout USBAccessoryPairingSet) -> Void
    ) throws

    /// Records `pairing` against `instance` and drops its key from every other
    /// VM, so one key names at most one VM.
    ///
    /// This is what makes moving a device between guests rewrite the rule: the
    /// rewrite *is* the uniqueness, not a mechanism beside it. The other VMs
    /// are written first, so a write that fails never leaves the key on two.
    func pairUSBAccessory(_ pairing: USBAccessoryPairing, with instance: VMInstance) throws
}
