import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaLogging
import Security

/// Answers what this build's signature authorizes, so feature UI can degrade
/// gracefully in builds signed without a restricted entitlement.
///
/// The answer is a property of the signature, not the code, and a test runs in
/// the `xctest` runner or `KernovaTestHost`, each signed as itself rather than
/// as the app, so an answer read from the process would describe the runner.
package struct EntitlementService: Sendable {
    /// Whether VZ networking beyond NAT — bridged, host-only, and app-managed
    /// vmnet networks — is authorized (`com.apple.vm.networking`).
    ///
    /// Resolved once: the answer is a property of the running process's
    /// signature, which cannot change under it.
    package let hasVMNetworking: Bool

    /// Whether claiming a USB accessory for passthrough to a guest is
    /// authorized (`com.apple.developer.accessory-access.usb`).
    ///
    /// Resolved once, for the same reason as `hasVMNetworking`.
    let hasAccessoryAccess: Bool

    /// ``hasAccessoryAccess``, where AccessoryAccess exists. Below macOS 27 the
    /// entitlement authorizes nothing, so the macOS is what a caller deciding
    /// passthrough asks first.
    @available(macOS 27.0, *)
    package var authorizesAccessoryAccess: Bool { hasAccessoryAccess }

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

    /// The attachment that realizes `network` in this build, `nil` when this
    /// build cannot attach it — the one mapping every path that builds,
    /// recovers, observes, refuses or offers a network reads.
    ///
    /// Without `com.apple.vm.networking` the only attachment is system NAT,
    /// which every NAT guest joins, so it realizes NAT's common
    /// network and nothing else.
    package func realization(of network: VMJoinedNetwork) -> VMNetworkRealization? {
        switch network {
        case .bridged:
            return hasVMNetworking ? .bridged : nil
        case .vmnet(let id):
            guard hasVMNetworking else {
                return id == .common(.nat) ? .systemNAT : nil
            }
            return .vmnet(VmnetNetworkSelection(id))
        }
    }

    /// Whether this build can attach a guest to `network`.
    package func canAttach(_ network: VMJoinedNetwork) -> Bool {
        realization(of: network) != nil
    }
}

// MARK: - Reading the Signature

extension EntitlementService {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "EntitlementService")

    /// What this process's own signature authorizes.
    package static func readFromProcess() -> EntitlementService {
        EntitlementService(
            hasVMNetworking: processClaims("com.apple.vm.networking"),
            hasAccessoryAccess: processClaims("com.apple.developer.accessory-access.usb"),
            hasTopologyObservation: processClaims(
                "com.apple.developer.networking.topology-observation"))
    }

    /// Whether this process's signature claims `key` with a boolean `true`
    /// value, via `SecTaskCopyValueForEntitlement`.
    static func processClaims(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else {
            logger.log(
                .fault,
                "SecTaskCreateFromSelf returned nil — treating entitlement '\(key, privacy: .public)' as absent"
            )
            assertionFailure("SecTaskCreateFromSelf returned nil")
            return false
        }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, key as CFString, &error)
        if let error = error?.takeRetainedValue() {
            logger.log(
                .warning,
                "Entitlement query for '\(key, privacy: .public)' failed — treating as absent: \(String(describing: error), privacy: .public)"
            )
        }
        return (value as? Bool) == true
    }
}

/// How a build attaches a guest to the network it joins.
package enum VMNetworkRealization: Equatable, Sendable {
    /// The system NAT attachment.
    case systemNAT
    /// A host interface, chosen when the attachment is made.
    case bridged
    /// An app-managed vmnet network, as the VM's own session names it.
    case vmnet(VmnetNetworkSelection)
}
