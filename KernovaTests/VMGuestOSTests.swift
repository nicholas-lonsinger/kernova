import Testing
import Foundation
@testable import Kernova

@Suite("VMGuestOS Tests")
struct VMGuestOSTests {

    // MARK: - Display Name

    @Test("displayName returns macOS for macOS guest")
    func macOSDisplayName() {
        #expect(VMGuestOS.macOS.displayName == "macOS")
    }

    @Test("displayName returns Linux for linux guest")
    func linuxDisplayName() {
        #expect(VMGuestOS.linux.displayName == "Linux")
    }

    // MARK: - Default Resource Values

    @Test("macOS defaults: 4 CPUs, 8 GB memory, 100 GB disk (clamped to hardware maximums)")
    func macOSDefaults() {
        #expect(VMGuestOS.macOS.defaultCPUCount == min(4, VMGuestOS.macOS.maxCPUCount))
        #expect(VMGuestOS.macOS.defaultMemoryInGB == min(8, VMGuestOS.macOS.maxMemoryInGB))
        #expect(VMGuestOS.macOS.defaultDiskSizeInGB == 100)
    }

    @Test("Linux defaults: 2 CPUs, 4 GB memory, 64 GB disk (clamped to hardware maximums)")
    func linuxDefaults() {
        #expect(VMGuestOS.linux.defaultCPUCount == min(2, VMGuestOS.linux.maxCPUCount))
        #expect(VMGuestOS.linux.defaultMemoryInGB == min(4, VMGuestOS.linux.maxMemoryInGB))
        #expect(VMGuestOS.linux.defaultDiskSizeInGB == 64)
    }

    // MARK: - Min Resource Constraints

    @Test("Minimum CPU count is 2 for both OS types")
    func minCPUCount() {
        #expect(VMGuestOS.macOS.minCPUCount == 2)
        #expect(VMGuestOS.linux.minCPUCount == 2)
    }

    @Test("Minimum memory is 4 GB for macOS and 2 GB for Linux")
    func minMemory() {
        #expect(VMGuestOS.macOS.minMemoryInGB == 4)
        #expect(VMGuestOS.linux.minMemoryInGB == 2)
    }

    @Test("Minimum disk size is 64 GB for macOS and 10 GB for Linux")
    func minDiskSize() {
        #expect(VMGuestOS.macOS.minDiskSizeInGB == 64)
        #expect(VMGuestOS.linux.minDiskSizeInGB == 10)
    }

    // MARK: - Max Resource Constraints

    @Test("Max CPU count matches host processor count")
    func maxCPUCount() {
        let hostProcessorCount = ProcessInfo.processInfo.processorCount
        #expect(VMGuestOS.macOS.maxCPUCount == hostProcessorCount)
        #expect(VMGuestOS.linux.maxCPUCount == hostProcessorCount)
    }

    @Test("Max memory matches host physical memory in GB")
    func maxMemory() {
        let hostMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        #expect(VMGuestOS.macOS.maxMemoryInGB == hostMemoryGB)
        #expect(VMGuestOS.linux.maxMemoryInGB == hostMemoryGB)
    }

    @Test("Max disk size is 2048 GB for both OS types")
    func maxDiskSize() {
        #expect(VMGuestOS.macOS.maxDiskSizeInGB == 2048)
        #expect(VMGuestOS.linux.maxDiskSizeInGB == 2048)
    }

    // MARK: - Constraint Relationships

    @Test("macOS constraints satisfy min <= default <= max")
    func macOSConstraintOrder() {
        let os = VMGuestOS.macOS
        #expect(os.minCPUCount <= os.defaultCPUCount)
        #expect(os.defaultCPUCount <= os.maxCPUCount)
        #expect(os.minMemoryInGB <= os.defaultMemoryInGB)
        #expect(os.defaultMemoryInGB <= os.maxMemoryInGB)
        #expect(os.minDiskSizeInGB <= os.defaultDiskSizeInGB)
        #expect(os.defaultDiskSizeInGB <= os.maxDiskSizeInGB)
    }

    @Test("Linux constraints satisfy min <= default <= max")
    func linuxConstraintOrder() {
        let os = VMGuestOS.linux
        #expect(os.minCPUCount <= os.defaultCPUCount)
        #expect(os.defaultCPUCount <= os.maxCPUCount)
        #expect(os.minMemoryInGB <= os.defaultMemoryInGB)
        #expect(os.defaultMemoryInGB <= os.maxMemoryInGB)
        #expect(os.minDiskSizeInGB <= os.defaultDiskSizeInGB)
        #expect(os.defaultDiskSizeInGB <= os.maxDiskSizeInGB)
    }
}
