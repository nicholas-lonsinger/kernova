import KernovaKit
import Foundation

/// The account a macOS guest is asked to create on its first boot after
/// restore, minus the password.
///
/// The password is absent by construction rather than by omission: a bundle's
/// `config.json` is plain text beside the disks, and this is the part of an
/// account that can live there. The secret is held apart from the bundle, as a
/// ``GuestAccountPassword`` (``GuestAccountPasswordStoring``).
///
/// Persisted as ``VMConfiguration/pendingGuestAccount`` rather than inside the
/// install context: the install is over when the image lands, while the account
/// is owed until a boot has spent the one window macOS reads it in.
package struct GuestAccountIntent: Codable, Sendable, Equatable {
    package var fullName: String
    package var username: String
    package var logsInAutomatically: Bool
    package var enablesRemoteLogin: Bool
}

/// The account Virtualization creates inside a macOS guest, complete with the
/// password.
///
/// Not `Codable`: that conformance is what would let the password reach a
/// bundle's `config.json`. The other four values persist as
/// ``GuestAccountIntent``, and the password is rejoined with them for the boot
/// that carries it.
package struct GuestProvisioningCredentials: Sendable, CustomStringConvertible {
    package var fullName: String
    package var username: String
    package var password: String
    package var logsInAutomatically: Bool
    package var enablesRemoteLogin: Bool

    init(
        fullName: String, username: String, password: String, logsInAutomatically: Bool,
        enablesRemoteLogin: Bool
    ) {
        self.fullName = fullName
        self.username = username
        self.password = password
        self.logsInAutomatically = logsInAutomatically
        self.enablesRemoteLogin = enablesRemoteLogin
    }

    /// Rejoins a persisted intent with the secret it was stored without.
    init(intent: GuestAccountIntent, password: String) {
        self.init(
            fullName: intent.fullName, username: intent.username, password: password,
            logsInAutomatically: intent.logsInAutomatically,
            enablesRemoteLogin: intent.enablesRemoteLogin)
    }

    /// Redacts the password, so interpolating these into a log line or a
    /// debugger dump cannot spill it.
    package var description: String {
        "GuestProvisioningCredentials(fullName: \(fullName), username: \(username), "
            + "password: <redacted>, logsInAutomatically: \(logsInAutomatically), "
            + "enablesRemoteLogin: \(enablesRemoteLogin))"
    }
}

/// A set of credentials Virtualization refused, as the framework described it.
package struct GuestProvisioningRefusal: Sendable, Equatable {
    /// The control the refusal belongs to.
    package enum Field: Sendable, Equatable {
        case fullName
        case username
        case password
        /// A refusal Virtualization named no field for.
        case unknown
    }

    let field: Field

    /// What the user is told, shown as written.
    ///
    /// Virtualization's own reason wherever it gave one: Apple words and
    /// localizes it, and the framework publishes no rule for a username or a
    /// password that could be restated here without refusing input
    /// Virtualization accepts. Whichever it is, it names no API — see
    /// ``MacOSGuestProvisioning/refusal(from:)``.
    let message: String

    package init(field: GuestProvisioningRefusal.Field, message: String) {
        self.field = field
        self.message = message
    }
}

/// The account fields a surface has controls for, and so may refuse as blank.
///
/// The wizard's Account step gathers the whole account; the prompt a start
/// raises gathers the password alone, the rest arriving from a persisted
/// ``GuestAccountIntent`` it shows no editor for.
struct GatheredAccountFields: OptionSet, Sendable {
    let rawValue: Int

    static let fullName = GatheredAccountFields(rawValue: 1 << 0)
    static let username = GatheredAccountFields(rawValue: 1 << 1)
    static let password = GatheredAccountFields(rawValue: 1 << 2)

    static let wholeAccount: GatheredAccountFields = [.fullName, .username, .password]
}

/// Where the macOS guest-account capability is decided, once: whether to offer
/// it, whether a boot can deliver it, what Virtualization makes of a given
/// account, and the start options that carry it.
package enum MacOSGuestProvisioning {
    /// The guest release that runs Virtualization's provisioning protocol.
    ///
    /// An older guest ignores the options and stops at Setup Assistant, with no
    /// error raised anywhere (`VZMacGuestProvisioningOptions`).
    static let guestFloor = MacOSVersion(major: 27, minor: 0)

    /// Whether this host's Virtualization carries the provisioning API at all.
    static var hostSupportsProvisioning: Bool {
        guard #available(macOS 27.0, *) else { return false }
        return true
    }

    /// Whether to offer unattended setup for a restore image at
    /// `imageVersion` — what the wizard asks, before an install has run.
    ///
    /// An image whose version nothing has read (`nil`) is offered nothing. The
    /// toggle promises an account, and a guest below ``guestFloor`` discards
    /// the options in silence, so offering on a guess risks exactly the
    /// invisible failure "Capability degrades by absence" exists to prevent.
    static func offersUnattendedSetup(forImageVersion imageVersion: MacOSVersion?) -> Bool {
        guard hostSupportsProvisioning, let imageVersion else { return false }
        return imageVersion.isAtLeast(guestFloor)
    }

    /// Whether the guest `configuration` describes can act on provisioning —
    /// what the boot asks, once the installed image has said what it was.
    static func canProvision(_ configuration: VMConfiguration) -> Bool {
        guard hostSupportsProvisioning, configuration.guestOS == .macOS,
            let version = configuration.effectiveGuestMacOSVersion
        else { return false }
        return version.isAtLeast(guestFloor)
    }

    /// What stops `credentials` creating the account, in the order the user
    /// meets it — or `nil` when Virtualization accepts them.
    ///
    /// The one enforcement path behind every surface that gathers an account:
    /// a completeness check over the fields `gathered` names, the verification
    /// check, then Virtualization's own verdict shown as written.
    ///
    /// Both the fields and `incompleteMessage` are the caller's, because a
    /// surface can only ask for what it has controls for: "finish filling this
    /// in" is true of a blank field the user can type into and false of one
    /// they cannot reach, which would otherwise refuse forever whatever they
    /// type. A value outside `gathered` still reaches Virtualization, whose
    /// verdict names what is actually wrong with it.
    ///
    /// `credentials` are taken exactly as the account would be created, so
    /// trimming belongs to whatever gathered them.
    static func refusal(
        for credentials: GuestProvisioningCredentials, verifiedBy verification: String,
        gathering gathered: GatheredAccountFields, incomplete incompleteMessage: String,
        host: any VirtualizationHostProviding
    ) -> String? {
        let blanks: [(GatheredAccountFields, String)] = [
            (.fullName, credentials.fullName),
            (.username, credentials.username),
            (.password, credentials.password),
            // The verification is the second spelling of the password, so it is
            // gathered exactly where the password is.
            (.password, verification),
        ]
        guard !blanks.contains(where: { gathered.contains($0.0) && $0.1.isEmpty }) else {
            return incompleteMessage
        }
        guard credentials.password == verification else {
            return "The passwords don\u{2019}t match."
        }
        return host.guestAccountRefusal(credentials)?.message
    }

    /// What stops `password` completing the account `fullName` and `username`
    /// name, or `nil` when Virtualization accepts it.
    ///
    /// The spelling for a surface whose only control is the password: the rest
    /// of the account is already persisted, so a message about a field the user
    /// cannot reach would refuse forever whatever they type.
    ///
    /// The account's two login flags take any value Virtualization validates,
    /// so this passes the ones a fresh account would get; what comes back is
    /// about the password and nothing else.
    package static func passwordRefusal(
        fullName: String, username: String, password: String, verifiedBy verification: String,
        host: any VirtualizationHostProviding
    ) -> String? {
        refusal(
            for: GuestProvisioningCredentials(
                fullName: fullName, username: username, password: password,
                logsInAutomatically: false, enablesRemoteLogin: false),
            verifiedBy: verification, gathering: .password,
            incomplete: "Enter the password to continue.", host: host)
    }

    /// What a refusal that named no reason says, in the words the wizard's own
    /// labels use.
    package static func refusalMessage(for field: GuestProvisioningRefusal.Field) -> String {
        switch field {
        case .fullName: "macOS didn\u{2019}t accept this full name."
        case .username: "macOS didn\u{2019}t accept this account name."
        case .password: "macOS didn\u{2019}t accept this password."
        case .unknown: "macOS didn\u{2019}t accept this account."
        }
    }
}
