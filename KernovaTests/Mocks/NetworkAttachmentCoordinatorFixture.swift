import Foundation

@testable import Kernova

/// Wires a mock-backed `NetworkAttachmentCoordinator` onto `instance`, mirroring
/// `VMInstance.setupNetworkAttachmentCoordinator`: it reads the instance's live
/// configuration, publishes pending state onto the session context, and routes
/// both arbitration triggers — a suspected-defective network, and going pending
/// — to `instance.onNetworkArbitrationNeeded`.
///
/// Shared by every suite that needs an instance whose coordinator answers
/// `mayHoldAttachment(on:)` and `suspectsDefectiveNetwork(on:)` for real, rather
/// than the configuration fallback a coordinator-less instance gives.
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
    isVMNetworkingEntitled: Bool = false,
    retryDelays: [TimeInterval] = [],
    vmnetRematerializeDelays: [TimeInterval] = []
) -> NetworkAttachmentCoordinator {
    let coordinator = NetworkAttachmentCoordinator(
        vmName: instance.name,
        device: device,
        interfaces: provider,
        linkObserver: linkObserver,
        vmnetNetworks: vmnetNetworks,
        isVMNetworkingEntitled: isVMNetworkingEntitled,
        retryDelays: retryDelays,
        vmnetRematerializeDelays: vmnetRematerializeDelays,
        isEligible: { [weak instance] in
            guard let instance else { return false }
            return instance.status == .running || instance.status == .paused
        },
        choice: { [weak instance] in instance?.configuration.networkChoice },
        onPendingChange: { [weak instance] pending in
            instance?.sessionContext?.networkAttachmentPending = pending
            if pending { instance?.onNetworkArbitrationNeeded?() }
        },
        onNetworkDefectSuspected: { [weak instance] in
            instance?.onNetworkArbitrationNeeded?()
        })
    let context = instance.sessionContext ?? instance.beginSessionContext()
    context.networkAttachmentCoordinator = coordinator
    return coordinator
}
