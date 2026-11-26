import Foundation

@testable import KernovaCore

/// A `VirtualizationHostProviding` with fixed answers, so what a test reads as
/// this Mac's limits, fresh identities and verdicts on a guest account or a
/// share's name depends on neither the Mac nor the Virtualization framework.
package struct FakeVirtualizationHost: VirtualizationHostProviding {
    /// The bounds Virtualization reports on an Apple silicon Mac with 32 GiB of
    /// memory.
    package static let resourceLimits = VMResourceLimits(
        cpuCount: InclusiveBounds(lower: 1, upper: 64),
        memoryBytes: InclusiveBounds(lower: 4 << 20, upper: 32 << 30))

    /// What ``guestAccountRefusal(_:)`` answers for every set of credentials.
    package var refusal: GuestProvisioningRefusal?
    /// The names ``directoryShareNameRefusal(_:)`` refuses; it accepts every
    /// other.
    package var refusedDirectoryShareNames: Set<String>

    package init(refusal: GuestProvisioningRefusal? = nil, refusedDirectoryShareNames: Set<String> = []) {
        self.refusal = refusal
        self.refusedDirectoryShareNames = refusedDirectoryShareNames
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

    package func directoryShareNameRefusal(_ name: String) -> (any Error)? {
        refusedDirectoryShareNames.contains(name) ? CocoaError(.fileWriteInvalidFileName) : nil
    }
}
