import Foundation
import KernovaKit
import Testing
import Virtualization

@testable import Kernova

@Suite("VMResourceLimits Tests", .caseScoped)
struct VMResourceLimitsTests {
    // MARK: - Framework bounds

    @Test("CPU bounds are the Virtualization framework's")
    func cpuBoundsAreTheFrameworks() {
        #expect(VMResourceLimits.cpuCount.lower == VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        #expect(VMResourceLimits.cpuCount.upper == VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    @Test("Memory bounds are the Virtualization framework's, in whole mebibytes")
    func memoryBoundsAreTheFrameworks() {
        let lower = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let upper = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        #expect(VMResourceLimits.memorySize.lower.bytes >= lower)
        #expect(VMResourceLimits.memorySize.lower.bytes - lower < 1 << 20)
        #expect(VMResourceLimits.memorySize.upper.bytes <= upper)
        #expect(upper - VMResourceLimits.memorySize.upper.bytes < 1 << 20)
    }

    @Test("A bounds check with the bounds out of order refuses every value rather than trapping")
    func invertedBoundsRefuse() {
        let inverted = InclusiveBounds(lower: 10, upper: 2)
        #expect(!inverted.contains(2))
        #expect(!inverted.contains(5))
        #expect(!inverted.contains(10))
        #expect(InclusiveBounds(lower: 2, upper: 10).contains(2))
        #expect(InclusiveBounds(lower: 2, upper: 10).contains(10))
        #expect(!InclusiveBounds(lower: 2, upper: 10).contains(11))
    }
}
