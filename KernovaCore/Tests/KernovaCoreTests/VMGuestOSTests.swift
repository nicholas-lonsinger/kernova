import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMGuestOS Tests", .caseScoped)
struct VMGuestOSTests {
    // MARK: - Default Resource Values

    /// A Mac with room for every preferred default.
    private let roomy = VMResourceLimits(
        cpuCount: InclusiveBounds(lower: 1, upper: 64),
        memoryBytes: InclusiveBounds(lower: 1 << 27, upper: 1 << 40))

    /// A Mac with less than either guest prefers.
    private let tight = VMResourceLimits(
        cpuCount: InclusiveBounds(lower: 1, upper: 1),
        memoryBytes: InclusiveBounds(lower: 1 << 27, upper: 3 << 30))

    @Test("macOS defaults: 4 CPUs, 8 GB memory, within the host's bounds")
    func macOSDefaults() {
        #expect(VMGuestOS.macOS.defaultCPUCount(within: roomy) == 4)
        #expect(VMGuestOS.macOS.defaultMemorySize(within: roomy) == .gibibytes(8))
        #expect(VMGuestOS.macOS.defaultCPUCount(within: tight) == 1)
        #expect(VMGuestOS.macOS.defaultMemorySize(within: tight) == .gibibytes(3))
    }

    @Test("Linux defaults: 2 CPUs, 4 GB memory, within the host's bounds")
    func linuxDefaults() {
        #expect(VMGuestOS.linux.defaultCPUCount(within: roomy) == 2)
        #expect(VMGuestOS.linux.defaultMemorySize(within: roomy) == .gibibytes(4))
        #expect(VMGuestOS.linux.defaultCPUCount(within: tight) == 1)
        #expect(VMGuestOS.linux.defaultMemorySize(within: tight) == .gibibytes(3))
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
