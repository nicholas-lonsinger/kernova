import Foundation
import KernovaCore
import Virtualization

/// This Mac's answers, as Virtualization gives them.
package struct VirtualizationHost: VirtualizationHostProviding {
    /// The framework's own bounds, which are the same for every guest.
    static let frameworkResourceLimits = VMResourceLimits(
        cpuCount: InclusiveBounds(
            lower: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            upper: VZVirtualMachineConfiguration.maximumAllowedCPUCount),
        memoryBytes: InclusiveBounds(
            lower: VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            upper: VZVirtualMachineConfiguration.maximumAllowedMemorySize))

    package init() {}

    package var resourceLimits: VMResourceLimits { Self.frameworkResourceLimits }

    package func makeMacMachineIdentifier() -> Data {
        VZMacMachineIdentifier().dataRepresentation
    }

    package func makeGenericMachineIdentifier() -> Data {
        VZGenericMachineIdentifier().dataRepresentation
    }

    package func guestAccountRefusal(_ credentials: GuestProvisioningCredentials) -> GuestProvisioningRefusal? {
        MacOSGuestProvisioning.validate(credentials)
    }
}
