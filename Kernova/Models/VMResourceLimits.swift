import Virtualization

/// The CPU and memory a virtual machine may be given, as the Virtualization
/// framework reports them for this Mac — the same for every guest.
enum VMResourceLimits {
    static let cpuCount = InclusiveBounds(
        lower: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
        upper: VZVirtualMachineConfiguration.maximumAllowedCPUCount)

    /// The framework's byte bounds, narrowed to whole mebibytes.
    static let memorySize = InclusiveBounds(
        lower: VMMemorySize(roundingUp: VZVirtualMachineConfiguration.minimumAllowedMemorySize),
        upper: VMMemorySize(roundingDown: VZVirtualMachineConfiguration.maximumAllowedMemorySize))
}
