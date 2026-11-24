import Foundation

/// What a wait for a virtual machine waits for.
public enum WaitCondition: String, Codable, Sendable, Hashable, CaseIterable {
    /// The VM is running.
    case running
    /// The VM is stopped.
    case stopped
    /// The guest agent is connected and runs the payload the host bundles.
    case agent
    /// Kernova has seen the guest use an address on its network
    /// (``GuestIPAddress/observed(_:)``).
    case address

    /// What a wait that gave up on `vm` after `seconds` observed.
    fileprivate func unmetSentence(vm: String, seconds: TimeInterval) -> String {
        let vm = "\u{201C}\(vm)\u{201D}"
        let within = "within \(CommandTimeout.text(seconds)) seconds."
        return switch self {
        case .running: "\(vm) was not running \(within)"
        case .stopped: "\(vm) was not stopped \(within)"
        case .agent: "\(vm) had no up-to-date guest agent connected \(within)"
        case .address: "Kernova had not seen \(vm) on its network \(within)"
        }
    }
}

/// How a wait ended without its VM reaching the ``WaitCondition``.
public enum WaitEnding: Codable, Sendable, Hashable {
    /// `seconds` passed first.
    case timedOut(seconds: TimeInterval)
    /// The VM left the library.
    case removed
    /// What Kernova answers for the guest's address is not one a wait can see
    /// become an observed address.
    case noAddressToWaitFor(GuestAddressAbsence)

    /// What a surface tells the user about the wait for `vm` to meet
    /// `condition` ending this way.
    func message(vm: String, condition: WaitCondition) -> String {
        switch self {
        case .timedOut(let seconds): condition.unmetSentence(vm: vm, seconds: seconds)
        case .removed: "\u{201C}\(vm)\u{201D} left the library."
        case .noAddressToWaitFor(let absence): absence.sentence(vm: vm)
        }
    }
}
