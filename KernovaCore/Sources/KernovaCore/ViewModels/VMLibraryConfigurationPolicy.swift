import Foundation

/// The configuration policy every bundle a ``VMLibrary`` builds answers to:
/// the MAC-address and disk-image refusals across the library's VMs, and the
/// live policy, the removable-media reconcile and the guest-address watch a
/// moved configuration starts.
@MainActor
final class VMLibraryConfigurationPolicy {
    private let macAddresses: VMMACAddressRegistry
    private let liveIdentities: VMLiveIdentities
    private let removableMedia: VMRemovableMediaReconciler
    private let guestAddresses: GuestAddressObserver

    init(
        macAddresses: VMMACAddressRegistry, liveIdentities: VMLiveIdentities,
        removableMedia: VMRemovableMediaReconciler, guestAddresses: GuestAddressObserver
    ) {
        self.macAddresses = macAddresses
        self.liveIdentities = liveIdentities
        self.removableMedia = removableMedia
        self.guestAddresses = guestAddresses
    }

    /// Refuses a move onto a MAC address another VM holds, in its
    /// configuration or in one of its snapshots, and a running VM's move onto
    /// a disk image another active VM has open
    /// (``VMLiveIdentities/diskImageConflict(on:movingFrom:to:)``).
    ///
    /// A revert refuses nothing: the snapshot's saved state restores only
    /// under the address it was taken with, which ``VMMACAddressRegistry``
    /// keeps for this VM while the snapshot is listed.
    ///
    /// Runs inside the coordinated write, so it must be pure.
    func refusal(
        on instance: VMInstance, movingFrom old: VMConfiguration, to new: VMConfiguration,
        under authority: VMEditPermit.Authority
    ) -> (any Error)? {
        if case .operation(.bringUp(.reverting)) = authority { return nil }
        if let conflict = macAddresses.macAddressConflict(on: instance, movingFrom: old, to: new) {
            return VMLibrary.SettingsRefusal.macAddressInUse(conflict)
        }
        if let conflict = liveIdentities.diskImageConflict(on: instance, movingFrom: old, to: new) {
            return VMLibrary.SettingsRefusal.diskImageInUse(conflict)
        }
        return nil
    }

    /// Pushes the change to a running VM: the hot-toggleable fields through
    /// ``VMInstance/applyLivePolicy(oldConfig:newConfig:)``, an edit's
    /// `removableMedia` change through the reconcile it owes a live session;
    /// everything else waits for the next start. A dropped installer entry's
    /// copy goes with it.
    func committed(
        on instance: VMInstance, from old: VMConfiguration, to new: VMConfiguration,
        under authority: VMEditPermit.Authority
    ) {
        GuestAgentDiskCopies.removeCopies(droppedFrom: old, to: new, in: instance.bundleLayout)
        instance.applyLivePolicy(oldConfig: old, newConfig: new)
        removableMedia.apply(for: instance, old: old, new: new, under: authority)
        // A live switch onto an app-managed network starts a guest worth
        // watching without starting a session.
        guestAddresses.watch()
    }
}
