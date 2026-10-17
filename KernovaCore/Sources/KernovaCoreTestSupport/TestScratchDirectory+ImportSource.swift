import Foundation
import KernovaKit

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

extension TestScratchDirectory {
    /// A `<name>.kernova` bundle in a fresh subdirectory, so two sources may
    /// share a name. `onDisk: false` returns the URL without creating anything.
    func importSource(name: String, onDisk: Bool = true) throws -> (url: URL, config: VMConfiguration) {
        let config = VMConfiguration(
            name: name, guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let bundleURL =
            url
            .appendingPathComponent("ImportSource-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("\(name).kernova", isDirectory: true)
        if onDisk {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try VMStagedBundle.fixtureForTesting(at: bundleURL, access: CoordinatedBundleFileAccess())
                .writeInitial(config)
        }
        return (bundleURL, config)
    }
}
