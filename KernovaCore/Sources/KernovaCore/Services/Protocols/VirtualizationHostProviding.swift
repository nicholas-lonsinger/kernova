import Foundation

/// What Virtualization answers about this Mac without a virtual machine: the
/// resources a guest may be given, fresh machine identities, and its verdicts
/// on a guest account and on a shared folder's name.
///
/// The engine answers it (`VirtualizationHost`); `KernovaApp` hands that to
/// everything that asks.
package protocol VirtualizationHostProviding: Sendable {
    /// The CPU and memory bounds every guest on this Mac is held to.
    var resourceLimits: VMResourceLimits { get }

    /// A fresh macOS guest machine identifier, as the bundle and
    /// ``VMConfiguration/machineIdentifierData`` store it.
    func makeMacMachineIdentifier() -> Data

    /// A fresh EFI and Linux-kernel guest machine identifier, as
    /// ``VMConfiguration/genericMachineIdentifierData`` stores it.
    func makeGenericMachineIdentifier() -> Data

    /// Virtualization's own verdict on `credentials`, or `nil` when it accepts
    /// them — see ``MacOSGuestProvisioning/refusal(for:verifiedBy:gathering:incomplete:host:)``.
    func guestAccountRefusal(_ credentials: GuestProvisioningCredentials) -> GuestProvisioningRefusal?

    /// Virtualization's own verdict on `name` as the name a macOS guest
    /// mounts a shared folder by, or `nil` when it accepts it.
    func directoryShareNameRefusal(_ name: String) -> (any Error)?
}
