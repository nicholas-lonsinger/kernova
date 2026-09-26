import Foundation

/// The configuration policy every bundle a ``VMLibrary`` builds answers to:
/// the MAC-address refusal across the library's VMs, and the live policy, the
/// removable-media reconcile and the guest-address watch a moved
/// configuration starts.
@MainActor
final class VMLibraryConfigurationPolicy: VMConfigurationPolicy {
    private let macAddresses: VMMACAddressRegistry
    private let removableMedia: VMRemovableMediaReconciler
    private let guestAddresses: GuestAddressObserver

    init(
        macAddresses: VMMACAddressRegistry, removableMedia: VMRemovableMediaReconciler,
        guestAddresses: GuestAddressObserver
    ) {
        self.macAddresses = macAddresses
        self.removableMedia = removableMedia
        self.guestAddresses = guestAddresses
    }

    /// Refuses a move onto a MAC address another VM holds, in its
    /// configuration or in one of its snapshots.
    ///
    /// A revert refuses nothing: the snapshot's saved state restores only
    /// under the address it was taken with, which ``VMMACAddressRegistry``
    /// keeps for this VM while the snapshot is listed.
    func refusal(
        on instance: VMInstance, movingFrom old: VMConfiguration, to new: VMConfiguration,
        under authority: VMEditPermit.Authority
    ) -> (any Error)? {
        if case .operation(.bringUp(.reverting)) = authority { return nil }
        guard let conflict = macAddresses.macAddressConflict(on: instance, movingFrom: old, to: new)
        else { return nil }
        return VMLibrary.SettingsRefusal.macAddressInUse(conflict)
    }

    /// Pushes the change to a running VM: the hot-toggleable fields through
    /// ``VMInstance/applyLivePolicy(oldConfig:newConfig:)``, a `removableMedia`
    /// change through the reconcile a settled live VM launches; everything
    /// else waits for the next start.
    func committed(on instance: VMInstance, from old: VMConfiguration, to new: VMConfiguration) {
        instance.applyLivePolicy(oldConfig: old, newConfig: new)
        removableMedia.apply(for: instance, old: old, new: new)
        // A live switch onto an app-managed network starts a guest worth
        // watching without starting a session.
        guestAddresses.watch()
    }
}
