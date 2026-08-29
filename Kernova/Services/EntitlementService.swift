import Foundation
import Security
import os

/// Reads entitlement values from a process's code signature, abstracted so
/// tests can inject a fake in place of the Security framework.
protocol EntitlementReading: Sendable {
    /// Whether the signature claims `key` with a boolean `true` value.
    func hasEntitlement(_ key: String) -> Bool
}

/// The real reader, answering from this process's own signature via
/// `SecTaskCopyValueForEntitlement`.
struct ProcessEntitlementReader: EntitlementReading {
    private static let logger = Logger(subsystem: "app.kernova", category: "ProcessEntitlementReader")

    func hasEntitlement(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else {
            Self.logger.fault(
                "SecTaskCreateFromSelf returned nil — treating entitlement '\(key, privacy: .public)' as absent"
            )
            assertionFailure("SecTaskCreateFromSelf returned nil")
            return false
        }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, key as CFString, &error)
        if let error = error?.takeRetainedValue() {
            Self.logger.warning(
                "Entitlement query for '\(key, privacy: .public)' failed — treating as absent: \(String(describing: error), privacy: .public)"
            )
        }
        return (value as? Bool) == true
    }
}

/// Answers what this build's signature authorizes, so feature UI can degrade
/// gracefully in builds signed without a restricted entitlement.
///
/// The answer is a property of the signature, not the code: the default
/// signing omits `com.apple.vm.networking` so profile-less builds run — see
/// docs/BUILD.md "Signing identity".
struct EntitlementService: Sendable {
    /// The process-wide instance over the real signature reader.
    @MainActor static let shared = EntitlementService()

    /// Whether VZ networking beyond NAT — bridged, host-only, and app-managed
    /// vmnet networks — is authorized (`com.apple.vm.networking`).
    ///
    /// Resolved once: the answer is a property of the running process's
    /// signature, which cannot change under it.
    let hasVMNetworking: Bool

    init(reader: any EntitlementReading = ProcessEntitlementReader()) {
        hasVMNetworking = reader.hasEntitlement("com.apple.vm.networking")
    }
}
