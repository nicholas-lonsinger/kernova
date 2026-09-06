import Foundation
import Security
import os

/// Whether the process on the other end of a connection may drive this app.
protocol PeerAuthorizing: Sendable {
    /// Whether the peer behind `token` is one this build answers.
    func isAuthorized(peer token: audit_token_t) -> Bool
}

/// Admits peers code-signed by this build's own team, and nothing else.
///
/// The whole authorization model for the command socket: the socket lives in an
/// app-group container only a same-team signature is granted, and the peer's
/// audit token is resolved to a `SecCode`, validated against Apple's roots, and
/// its team identifier compared with this build's own. No Keychain item, no
/// prompt, no shared secret — the signature is the credential, and it is one an
/// attacker cannot forge without the team's certificate.
///
/// The team comes from the signature's `kSecCodeInfoTeamIdentifier` rather than
/// from a `certificate leaf[subject.OU]` requirement, because a Mac App Store
/// build's leaf has no team OU: Apple re-signs store copies, and their
/// designated requirement takes the `field.1.2.840.113635.100.6.1.9` marker
/// branch instead. A leaf-OU requirement would refuse every peer in exactly the
/// configuration this app ships in.
///
/// `init?` answers `nil` for a build whose signature names no team, so an
/// ad-hoc build has no authorizer, publishes no socket, and degrades by
/// absence.
struct SameTeamPeerAuthorizer: PeerAuthorizing {
    /// Every peer has to chain to an Apple root before its team is even read —
    /// a self-signed binary can claim any team identifier it likes.
    private static let anchorRequirement = "anchor apple generic"

    /// The team this build was signed by, and the only one it answers.
    private let ownTeam: String

    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "SameTeamPeerAuthorizer")

    /// Reads this build's own team, or fails when it has none.
    init?() {
        // Read from this process's own signature, never written down: a
        // hardcoded team would admit the wrong peers in any build signed with
        // another one.
        guard let team = Self.ownTeamIdentifier() else {
            Self.logger.warning(
                "This build's signature names no team — no peer can be authorized, so the command socket stays closed"
            )
            return nil
        }
        ownTeam = team
    }

    func isAuthorized(peer token: audit_token_t) -> Bool {
        let attributes =
            [kSecGuestAttributeAudit: Data(Self.bytes(of: token))] as CFDictionary
        var peer: SecCode?
        let lookup = SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer)
        guard lookup == errSecSuccess, let peer else {
            Self.logger.warning(
                "A connecting peer could not be resolved to a code identity: OSStatus \(lookup, privacy: .public)"
            )
            return false
        }

        var requirement: SecRequirement?
        let built = SecRequirementCreateWithString(
            Self.anchorRequirement as CFString, [], &requirement)
        guard built == errSecSuccess, let requirement else {
            Self.logger.error(
                "Could not build the anchor requirement: OSStatus \(built, privacy: .public)")
            return false
        }
        let validity = SecCodeCheckValidity(peer, [], requirement)
        guard validity == errSecSuccess else {
            Self.logger.notice(
                "Refused a connecting peer that does not chain to an Apple root: OSStatus \(validity, privacy: .public)"
            )
            return false
        }

        guard Self.isSameTeam(peer: Self.teamIdentifier(of: peer), own: ownTeam) else {
            Self.logger.notice("Refused a connecting peer signed by a different team")
            return false
        }
        return true
    }

    /// Whether `peer` is the team this build answers.
    ///
    /// Pure, so the rule that decides it is testable without a second signed
    /// process: an absent team is an ad-hoc peer and is never a match, however
    /// this build was signed.
    static func isSameTeam(peer: String?, own: String) -> Bool {
        guard let peer, !peer.isEmpty, !own.isEmpty else { return false }
        return peer == own
    }

    /// This build's own team identifier, `nil` for an ad-hoc signature.
    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return teamIdentifier(of: code)
    }

    /// `code`'s team identifier, `nil` when its signature names none.
    private static func teamIdentifier(of code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let signing = information as? [String: Any]
        else { return nil }
        return signing[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The audit token's raw bytes, which is the form
    /// `kSecGuestAttributeAudit` takes.
    private static func bytes(of token: audit_token_t) -> [UInt8] {
        withUnsafeBytes(of: token) { Array($0) }
    }
}
