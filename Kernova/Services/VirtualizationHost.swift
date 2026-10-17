import Foundation
import KernovaCore
import Virtualization

/// This Mac's answers, as Virtualization gives them.
struct VirtualizationHost: VirtualizationHostProviding {
    /// The framework's own bounds, which are the same for every guest.
    static let frameworkResourceLimits = VMResourceLimits(
        cpuCount: InclusiveBounds(
            lower: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            upper: VZVirtualMachineConfiguration.maximumAllowedCPUCount),
        memoryBytes: InclusiveBounds(
            lower: VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            upper: VZVirtualMachineConfiguration.maximumAllowedMemorySize))

    var resourceLimits: VMResourceLimits { Self.frameworkResourceLimits }

    func makeMacMachineIdentifier() -> Data {
        VZMacMachineIdentifier().dataRepresentation
    }

    func makeGenericMachineIdentifier() -> Data {
        VZGenericMachineIdentifier().dataRepresentation
    }

    func guestAccountRefusal(_ credentials: GuestProvisioningCredentials) -> GuestProvisioningRefusal? {
        MacOSGuestProvisioning.validate(credentials)
    }
}
