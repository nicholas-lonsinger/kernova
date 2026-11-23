import Foundation
import KernovaCommandModel

@testable import KernovaCore

extension NetworkChoice {
    /// The choice a VM on `mode` with `membership` makes, derived through
    /// ``VMConfiguration/networkChoice`` so a test names the network the way
    /// the user picks it and still reads the one membership mapping.
    init(
        mode: VMNetworkMode, bridgedInterfaceIdentifier: String?,
        membership: VMNetworkMembership = .common
    ) {
        let config = VMConfiguration(
            name: "Choice",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize,
            networkEnabled: true,
            networkMode: mode,
            bridgedInterfaceIdentifier: bridgedInterfaceIdentifier,
            networkMembership: membership)
        guard let choice = config.networkChoice else {
            preconditionFailure("A configuration with a network device names a choice")
        }
        self = choice
    }
}
