@testable import KernovaCore

extension EntitlementService {
    /// The shipping signature's answer: every restricted key claimed.
    static let entitled = EntitlementService(
        hasVMNetworking: true, hasAccessoryAccess: true, hasTopologyObservation: true)

    /// The default signing's answer: no restricted key claimed.
    static let unentitled = EntitlementService(
        hasVMNetworking: false, hasAccessoryAccess: false, hasTopologyObservation: false)
}
