import Foundation
import KernovaCommandModel
import KernovaCore
import KernovaLogging
import Virtualization

/// The guest-account capability where it meets Virtualization: the start
/// options that carry an account, and the framework's verdict on one.
extension MacOSGuestProvisioning {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "MacOSGuestProvisioning")

    /// The one-shot start options a boot carries, or `nil` when it needs none.
    ///
    /// A recovery boot carries no provisioning whatever it was handed: macOS
    /// evaluates the options on the first boot after restore alone, so a
    /// recovery boot that spent that one would leave the account uncreated with
    /// nothing left to retry.
    ///
    /// An account Virtualization refuses here starts the guest unprovisioned,
    /// at Setup Assistant: that is the whole of the loss, where refusing the
    /// start would leave the user a VM that will not come up at all.
    ///
    /// `nonisolated` so the fresh options object stays in a disconnected region
    /// the session's `sending` parameter can take.
    nonisolated static func macOSStartOptions(
        bootIntoRecovery: Bool, guestOS: VMGuestOS, provisioning: GuestProvisioningCredentials?
    ) -> VZMacOSVirtualMachineStartOptions? {
        guard guestOS == .macOS else { return nil }
        if bootIntoRecovery {
            let options = VZMacOSVirtualMachineStartOptions()
            options.startUpFromMacOSRecovery = true
            return options
        }
        guard let provisioning, #available(macOS 27.0, *) else { return nil }
        let options = VZMacOSVirtualMachineStartOptions()
        do {
            try options.setGuestProvisioning(provisioningOptions(for: provisioning))
        } catch {
            // The framework's own description, domain and code — what the
            // refusal shown to the user leaves out, and the only record
            // of why a guest came up unprovisioned.
            let nsError = error as NSError
            logger.log(
                .warning,
                "Starting without the guest account '\(provisioning.username, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)]"
            )
            return nil
        }
        // A boot that carries an account spends the one window macOS reads it
        // in, so it is the irreversible step `.notice` exists for — and the
        // only positive evidence that an account was ever handed over, when a
        // guest turns out not to have one.
        logger.log(
            .notice,
            "Starting with the guest account '\(provisioning.username, privacy: .public)'")
        return options
    }

    /// Virtualization's own verdict on `credentials`, or `nil` when it accepts
    /// them.
    ///
    /// `VZGuestProvisioningOptions.validate()` needs neither a VM nor the
    /// virtualization entitlement, so it is the rule every surface that gathers
    /// an account asks — there is no second, client-side spelling of what a
    /// username or a password may be. A host below macOS 27 offers no account
    /// to gather, so it refuses nothing here.
    static func validate(_ credentials: GuestProvisioningCredentials) -> GuestProvisioningRefusal? {
        guard #available(macOS 27.0, *) else { return nil }
        do {
            try provisioningOptions(for: credentials).validate()
            return nil
        } catch {
            return refusal(from: error)
        }
    }

    /// The field a `VZError` guest-provisioning code names, paired with
    /// Virtualization's own message.
    ///
    /// Anything else is ``GuestProvisioningRefusal/Field/unknown``: a refusal
    /// naming no field is still a refusal, and its message is still the only
    /// thing worth showing.
    ///
    /// The message is the failure *reason* ("Short name 'ada lovelace' is not
    /// valid"), not `localizedDescription`, which prefixes it with a
    /// developer-facing framing naming the API ("Invalid username for guest
    /// provisioning."). A refusal carrying no reason is stated as what is known
    /// — which control macOS turned down — rather than falling back to that
    /// framing.
    @available(macOS 27.0, *)
    static func refusal(from error: any Error) -> GuestProvisioningRefusal {
        let nsError = error as NSError
        let code =
            nsError.domain == VZError.errorDomain ? VZError.Code(rawValue: nsError.code) : nil
        let field: GuestProvisioningRefusal.Field =
            switch code {
            case .guestProvisioningInvalidFullName: .fullName
            case .guestProvisioningInvalidUsername: .username
            case .guestProvisioningInvalidPassword: .password
            default: .unknown
            }
        return GuestProvisioningRefusal(
            field: field, message: nsError.localizedFailureReason ?? refusalMessage(for: field))
    }

    /// `credentials` as the framework object that validates and applies them.
    @available(macOS 27.0, *)
    private static func provisioningOptions(
        for credentials: GuestProvisioningCredentials
    ) -> VZMacGuestProvisioningOptions {
        let options = VZMacGuestProvisioningOptions()
        options.fullName = credentials.fullName
        options.username = credentials.username
        options.password = credentials.password
        options.logsInAutomatically = credentials.logsInAutomatically
        options.enablesRemoteLogin = credentials.enablesRemoteLogin
        return options
    }
}
