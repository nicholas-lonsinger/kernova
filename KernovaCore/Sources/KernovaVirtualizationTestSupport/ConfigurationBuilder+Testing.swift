import Foundation
import KernovaCommandModel
import KernovaTestSupport

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization

extension ConfigurationBuilder {
    /// A builder over `networks`' service, attaching through `attachments` —
    /// fresh ones by default — on the live host's bridgeable interfaces.
    static func testing(
        _ networks: ScriptedVmnetNetworks = ScriptedVmnetNetworks(),
        attachments: MockVmnetAttachments = MockVmnetAttachments(),
        entitlements: EntitlementService = .unentitled,
        guestAgentInstaller: URL? = nil
    ) -> ConfigurationBuilder {
        ConfigurationBuilder(
            bridgedInterfaces: HostBridgedInterfaceProvider(), vmnetNetworks: networks.service,
            vmnetAttachments: attachments.maker, entitlements: entitlements,
            guestAgent: BundledGuestAgent(version: "2.0", installerDiskImageURL: guestAgentInstaller))
    }
}

extension TestScratchDirectory {
    /// A new bundle directory under this scratch directory, holding an empty
    /// main disk file when `withDisk` is on and the EFI variable store a
    /// bring-up creates before an EFI build unless `withEFIVariableStore` is
    /// off.
    func makeEngineBundle(withDisk: Bool = false, withEFIVariableStore: Bool = true) throws -> URL {
        let bundleURL = url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        if withDisk {
            try Data().write(to: VMBundleLayout(bundleURL: bundleURL).diskImageURL)
        }
        if withEFIVariableStore {
            try VirtualizationPlatformFiles().ensureEFIVariableStore(bundleURL: bundleURL)
        }
        return bundleURL
    }
}

extension VMConfiguration {
    /// A Linux guest booting through EFI at the host's default resources.
    static func testLinux(sharedDirectories: [SharedDirectory]? = nil) -> VMConfiguration {
        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.sharedDirectories = sharedDirectories
        return config
    }
}
