import AppKit

@testable import Kernova

/// Stands in for `NSApp`'s activation policy, hidden state and activation,
/// so no test changes the test host's Dock presence or asks for the front.
///
/// Holds the state a test gives it, and records every request in order.
@MainActor
final class TestAppPresence: AppPresence {
    enum Request: Equatable {
        case setActivationPolicy(NSApplication.ActivationPolicy)
        case activate
        case unhideWithoutActivation
    }

    var activationPolicy: NSApplication.ActivationPolicy
    let isActive: Bool
    /// Held across an unhide, so every presentation that would unhide records
    /// its own request.
    let isHidden: Bool
    private(set) var requests: [Request] = []

    init(
        activationPolicy: NSApplication.ActivationPolicy = .regular, isActive: Bool = false,
        isHidden: Bool = false
    ) {
        self.activationPolicy = activationPolicy
        self.isActive = isActive
        self.isHidden = isHidden
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        activationPolicy = policy
        requests.append(.setActivationPolicy(policy))
    }

    func activate() { requests.append(.activate) }

    func unhideWithoutActivation() { requests.append(.unhideWithoutActivation) }
}
