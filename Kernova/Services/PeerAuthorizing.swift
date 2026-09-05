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
/// audit token is resolved to a `SecCode` and checked against a requirement
/// naming that team. No Keychain item, no prompt, no shared secret — the
/// signature is the credential, and it is one an attacker cannot forge without
/// the team's certificate.
///
/// `init?` answers `nil` for a build whose signature names no team, so an
/// ad-hoc build has no authorizer, publishes no socket, and degrades by
/// absence.
struct SameTeamPeerAuthorizer: PeerAuthorizing {
    /// The requirement text, kept as the `String` a `SecRequirement` is built
    /// from per check: `SecRequirement` is a CoreFoundation type Swift 6 will
    /// not carry across isolation, and a connection is rare enough that
    /// rebuilding costs nothing measurable.
    private let requirementText: String

    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "SameTeamPeerAuthorizer")

    /// Reads this build's own team, or fails when it has none.
    init?() {
        guard let team = Self.ownTeamIdentifier() else {
            Self.logger.warning(
                "This build's signature names no team — no peer can be authorized, so the command socket stays closed"
            )
            return nil
        }
        // The team is read from this process's own signature, never written
        // down: a hardcoded team would admit the wrong peers in any build
        // signed with another one.
        requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    func isAuthorized(peer token: audit_token_t) -> Bool {
        var requirement: SecRequirement?
        let built = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard built == errSecSuccess, let requirement else {
            Self.logger.error(
                "Could not build the same-team requirement: OSStatus \(built, privacy: .public)")
            return false
        }
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
        let validity = SecCodeCheckValidity(peer, [], requirement)
        guard validity == errSecSuccess else {
            Self.logger.notice(
                "Refused a connecting peer that is not signed by this build's team: OSStatus \(validity, privacy: .public)"
            )
            return false
        }
        return true
    }

    /// This build's own team identifier, `nil` for an ad-hoc signature.
    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
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
