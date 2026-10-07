import Foundation
import KernovaLogging
import Security

/// Reads entitlement values from a process's code signature, abstracted so
/// tests can inject a fake in place of the Security framework.
protocol EntitlementReading: Sendable {
    /// Whether the signature claims `key` with a boolean `true` value.
    func hasEntitlement(_ key: String) -> Bool
}

/// The real reader, answering from this process's own signature via
/// `SecTaskCopyValueForEntitlement`.
struct ProcessEntitlementReader: EntitlementReading {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "ProcessEntitlementReader")

    func hasEntitlement(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else {
            #log(
                Self.logger, .fault,
                "SecTaskCreateFromSelf returned nil — treating entitlement '\(key, privacy: .public)' as absent"
            )
            assertionFailure("SecTaskCreateFromSelf returned nil")
            return false
        }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, key as CFString, &error)
        if let error = error?.takeRetainedValue() {
            #log(
                Self.logger, .warning,
                "Entitlement query for '\(key, privacy: .public)' failed — treating as absent: \(String(describing: error), privacy: .public)"
            )
        }
        return (value as? Bool) == true
    }
}

/// Answers what this build's signature authorizes, so feature UI can degrade
/// gracefully in builds signed without a restricted entitlement.
///
/// The answer is a property of the signature, not the code, and under test the
/// process is the test host, whose signing follows the machine: a gitignored
/// `Config/Local.xcconfig` can opt into the restricted keys the default signing
/// omits. An answer read from the process makes a test's outcome depend on
/// where it runs.
struct EntitlementService: Sendable {
    /// Whether VZ networking beyond NAT — bridged, host-only, and app-managed
    /// vmnet networks — is authorized (`com.apple.vm.networking`).
    ///
    /// Resolved once: the answer is a property of the running process's
    /// signature, which cannot change under it.
    let hasVMNetworking: Bool

    /// Whether claiming a USB accessory for passthrough to a guest is
    /// authorized (`com.apple.developer.accessory-access.usb`).
    ///
    /// Resolved once, for the same reason as `hasVMNetworking`.
    let hasAccessoryAccess: Bool

    /// Whether USB accessory passthrough can work at all in this process —
    /// both the entitlement and the OS that carries the API.
    ///
    /// The single value every accessory surface reads, so the capability
    /// appears and disappears in one place rather than per surface.
    var supportsUSBAccessories: Bool {
        if #available(macOS 27.0, *) { hasAccessoryAccess } else { false }
    }

    /// Whether reading the host's ARP table is authorized
    /// (`com.apple.developer.networking.topology-observation`).
    ///
    /// Resolved once, for the same reason as `hasVMNetworking`.
    let hasTopologyObservation: Bool

    /// Whether this process can read the host's ARP table, which is where a
    /// guest's address is observed — the single value every address surface
    /// reads.
    ///
    /// macOS 27 returns the table empty to an app without the key
    /// (https://developer.apple.com/forums/thread/822025?page=2).
    var supportsGuestAddressObservation: Bool {
        if #available(macOS 27.0, *) { hasTopologyObservation } else { true }
    }

    init(reader: any EntitlementReading) {
        hasVMNetworking = reader.hasEntitlement("com.apple.vm.networking")
        hasAccessoryAccess = reader.hasEntitlement("com.apple.developer.accessory-access.usb")
        hasTopologyObservation = reader.hasEntitlement(
            "com.apple.developer.networking.topology-observation")
    }

    /// The attachment that realizes `network` in this build, `nil` when this
    /// build cannot attach it — the one mapping every path that builds,
    /// recovers, observes, refuses or offers a network reads.
    ///
    /// Without `com.apple.vm.networking` the only attachment is system NAT,
    /// which every NAT guest joins, so it realizes NAT's common
    /// network and nothing else.
    func realization(of network: VMJoinedNetwork) -> VMNetworkRealization? {
        switch network {
        case .bridged:
            return hasVMNetworking ? .bridged : nil
        case .vmnet(let id):
            guard hasVMNetworking else {
                return id == .common(.shared) ? .systemNAT : nil
            }
            return .vmnet(VmnetNetworkSelection(id))
        }
    }

    /// Whether this build can attach a guest to `network`.
    func canAttach(_ network: VMJoinedNetwork) -> Bool {
        realization(of: network) != nil
    }
}

/// How a build attaches a guest to the network it joins.
enum VMNetworkRealization: Equatable, Sendable {
    /// The system NAT attachment.
    case systemNAT
    /// A host interface, chosen when the attachment is made.
    case bridged
    /// An app-managed vmnet network, as the VM's own session names it.
    case vmnet(VmnetNetworkSelection)
}
