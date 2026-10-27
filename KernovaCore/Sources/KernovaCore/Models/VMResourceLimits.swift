import KernovaCommandModel

/// The CPU and memory a virtual machine may be given on this Mac — the same for
/// every guest, as ``VirtualizationHostProviding/resourceLimits`` reports them.
package struct VMResourceLimits: Sendable, Equatable {
    package let cpuCount: InclusiveBounds<Int>
    package let memorySize: InclusiveBounds<VMMemorySize>

    /// Bounds from a CPU count range and a byte range, the byte bounds narrowed
    /// to whole mebibytes.
    package init(cpuCount: InclusiveBounds<Int>, memoryBytes: InclusiveBounds<UInt64>) {
        self.cpuCount = cpuCount
        self.memorySize = InclusiveBounds(
            lower: VMMemorySize(roundingUp: memoryBytes.lower),
            upper: VMMemorySize(roundingDown: memoryBytes.upper))
    }
}
