import KernovaKit
import Testing
import Foundation
@testable import Kernova

@Suite("VMGuestOS Tests", .caseScoped)
struct VMGuestOSTests {
    // MARK: - Default Resource Values

    @Test("macOS defaults: 4 CPUs, 8 GB memory, within the framework's bounds")
    func macOSDefaults() {
        #expect(VMGuestOS.macOS.defaultCPUCount == VMResourceLimits.cpuCount.clamp(4))
        #expect(VMGuestOS.macOS.defaultMemorySize == VMResourceLimits.memorySize.clamp(.gibibytes(8)))
    }

    @Test("Linux defaults: 2 CPUs, 4 GB memory, within the framework's bounds")
    func linuxDefaults() {
        #expect(VMGuestOS.linux.defaultCPUCount == VMResourceLimits.cpuCount.clamp(2))
        #expect(VMGuestOS.linux.defaultMemorySize == VMResourceLimits.memorySize.clamp(.gibibytes(4)))
    }

    @Test("Default disk size is 100 GB, OS-independent, and one of the offered sizes")
    func defaultDiskSize() {
        #expect(VMGuestOS.defaultDiskSizeInGB == 100)
        #expect(VMGuestOS.allDiskSizes.contains(VMGuestOS.defaultDiskSizeInGB))
    }

    // MARK: - Display Capabilities

    @Test("Only macOS guests carry a display density")
    func displayDensitySupport() {
        #expect(VMGuestOS.macOS.supportsDisplayDensity)
        #expect(!VMGuestOS.linux.supportsDisplayDensity)
    }
}
