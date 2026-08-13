@testable import Kernova

/// Scripted stand-in for `NetworkDeviceControlling`, so coordinator tests drive
/// attachment state without a `VZNetworkDevice`, which only a live VM has.
@MainActor
final class MockNetworkDeviceControl: NetworkDeviceControlling {
    /// The attachment the device currently realizes; tests nil it to simulate
    /// the framework's disconnect behavior.
    var plan: NetworkAttachmentPlan?
    /// Bridge identifiers `apply` refuses, simulating the interface vanishing
    /// between resolution and attach.
    var refusedBridgeIdentifiers: Set<String> = []
    private(set) var appliedPlans: [NetworkAttachmentPlan] = []
    private(set) var detachCount = 0

    init(plan: NetworkAttachmentPlan? = nil) {
        self.plan = plan
    }

    var currentPlan: NetworkAttachmentPlan? { plan }

    func apply(_ plan: NetworkAttachmentPlan) -> Bool {
        if case .bridged(let identifier) = plan,
            refusedBridgeIdentifiers.contains(identifier)
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
}
