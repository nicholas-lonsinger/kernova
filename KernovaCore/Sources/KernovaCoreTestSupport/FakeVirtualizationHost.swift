import Foundation

@testable import KernovaCore

/// A `VirtualizationHostProviding` with fixed answers, so what a test reads as
/// this Mac's limits, fresh identities and guest-account verdict depends on
/// neither the Mac nor the Virtualization framework.
package struct FakeVirtualizationHost: VirtualizationHostProviding {
    /// The bounds Virtualization reports on an Apple silicon Mac with 32 GiB of
    /// memory.
    package static let resourceLimits = VMResourceLimits(
        cpuCount: InclusiveBounds(lower: 1, upper: 64),
        memoryBytes: InclusiveBounds(lower: 4 << 20, upper: 32 << 30))

    /// What ``guestAccountRefusal(_:)`` answers for every set of credentials.
    package var refusal: GuestProvisioningRefusal?

    package init(refusal: GuestProvisioningRefusal? = nil) {
        self.refusal = refusal
    }

    package var resourceLimits: VMResourceLimits { Self.resourceLimits }

    /// Bytes distinct per call; the core stores and compares them, never reads
    /// them.
    package func makeMacMachineIdentifier() -> Data {
        Data(UUID().uuidString.utf8)
    }

    package func makeGenericMachineIdentifier() -> Data {
        Data(UUID().uuidString.utf8)
    }

    package func guestAccountRefusal(_ credentials: GuestProvisioningCredentials) -> GuestProvisioningRefusal? {
        refusal
    }
}
