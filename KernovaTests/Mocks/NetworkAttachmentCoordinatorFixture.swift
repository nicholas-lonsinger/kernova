import KernovaKit
import Foundation

@testable import Kernova

/// Wires a mock-backed `NetworkAttachmentCoordinator` onto `instance`, mirroring
/// `VMInstance.setupNetworkAttachmentCoordinator`: it reads the instance's live
/// configuration and publishes pending state onto the session context.
@MainActor
@discardableResult
func attachNetworkCoordinator(
    to instance: VMInstance,
    device: MockNetworkDeviceControl,
    provider: MockBridgedInterfaceProvider = MockBridgedInterfaceProvider(),
    linkObserver: MockNetworkLinkObserver = MockNetworkLinkObserver(),
    vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
    // Pinned rather than read from the test host's signature, so the plans
    // these tests assert on don't vary with how it was signed.
    entitlements: EntitlementService = .unentitled,
    retryDelays: [TimeInterval] = [],
    vmnetRematerializeDelays: [TimeInterval] = []
) -> NetworkAttachmentCoordinator {
    let coordinator = NetworkAttachmentCoordinator(
        vmName: instance.name,
        device: device,
        interfaces: provider,
        linkObserver: linkObserver,
        vmnetNetworks: vmnetNetworks,
        entitlements: entitlements,
        retryDelays: retryDelays,
        vmnetRematerializeDelays: vmnetRematerializeDelays,
        isEligible: { [weak instance] in instance?.hasLiveSession ?? false },
        choice: { [weak instance] in instance?.configuration.networkChoice },
        onPendingChange: { [weak instance] pending in
            instance?.sessionContext?.networkAttachmentPending = pending
        })
    let context = instance.sessionContext ?? instance.beginSessionContextForTesting()
    context.networkAttachmentCoordinator = coordinator
    return coordinator
}

extension NetworkChoice {
    /// The choice a VM on `mode` with `membership` makes, derived through
    /// ``VMConfiguration/networkChoice`` so a test names the network the way
    /// the user picks it and still reads the one membership mapping.
    init(
        mode: VMNetworkMode, bridgedInterfaceIdentifier: String?,
        membership: VMNetworkMembership = .common
    ) {
        let config = VMConfiguration(
            name: "Choice", guestOS: .linux, bootMode: .efi, networkEnabled: true,
            networkMode: mode, bridgedInterfaceIdentifier: bridgedInterfaceIdentifier,
            networkMembership: membership)
        guard let choice = config.networkChoice else {
            preconditionFailure("A configuration with a network device names a choice")
        }
        self = choice
    }
}
