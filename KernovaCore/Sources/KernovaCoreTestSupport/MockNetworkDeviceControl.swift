import Foundation

@testable import KernovaCore

/// Scripted stand-in for `NetworkDeviceControlling`, so coordinator tests drive
/// attachment state without a `VZNetworkDevice`, which only a live VM has.
@MainActor
final class MockNetworkDeviceControl: NetworkDeviceControlling {
    /// The attachment the device currently realizes; tests nil it to simulate
    /// the framework's disconnect behavior.
    var plan: NetworkAttachmentPlan?
    /// Plans `apply` refuses, simulating the host withdrawing what the plan
    /// names between resolution and attach — a bridge interface vanishing, a
    /// vmnet network that will not materialize.
    var refusedPlans: [NetworkAttachmentPlan] = []
    private(set) var appliedPlans: [NetworkAttachmentPlan] = []
    private(set) var detachCount = 0
    /// The session view a vmnet plan joins its network through, refusing the
    /// plan while that network is not materialized — as the real handle does.
    let vmnetNetworks: VmnetSessionNetworks

    init(
        plan: NetworkAttachmentPlan? = nil,
        vmnetNetworks: VmnetSessionNetworks = VmnetNetworkService.scripted().sessionNetworks(ownedBy: UUID())
    ) {
        self.plan = plan
        self.vmnetNetworks = vmnetNetworks
    }

    var currentPlan: NetworkAttachmentPlan? { plan }

    func apply(_ plan: NetworkAttachmentPlan) -> Bool {
        guard !refusedPlans.contains(plan) else { return false }
        if let selection = plan.vmnetSelection,
            vmnetNetworks.joinedNetworkIfMaterialized(for: selection) == nil
        {
            return false
        }
        appliedPlans.append(plan)
        self.plan = plan
        return true
    }

    func detach() {
        detachCount += 1
        plan = nil
    }

    func attachmentWasDisconnected() {
        // Mirrors the real handle: the framework nils the attachment before
        // its disconnect callback, so the mirror clears with it.
        plan = nil
    }
}
