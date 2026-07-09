import Foundation
import Security
import os

/// Resolves the running executable's own Developer Team Identifier from its
/// code signature.
///
/// Used to pin an XPC peer requirement to "the same team as whoever signed
/// me" instead of a hardcoded team ID (#476) — the app and its embedded File
/// Provider extension are always co-signed by the same team, so reading the
/// team back at runtime is both portable across clones and, unlike a literal,
/// automatically correct for both Debug (Apple Development) and Release
/// (Developer ID) signing.
public enum KernovaCodeSignature {
    private static let logger = Logger(subsystem: "app.kernova", category: "CodeSignature")

    /// Computed once: the running process's own code signature doesn't
    /// change over its lifetime, and Swift's `static let` initializer is
    /// itself thread-safe.
    private static let cachedTeamIdentifier: String? = resolveTeamIdentifier()

    /// The Developer Team Identifier (certificate Subject OU — the same
    /// field `Tools/bootstrap-team.sh` derives `DEVELOPMENT_TEAM` from) the
    /// running executable is signed with.
    ///
    /// - Returns: the team identifier, or `nil` if the running code is
    ///   unsigned or ad-hoc signed (no team identifier in the signature —
    ///   e.g. some test-host configurations).
    public static func teamIdentifier() -> String? {
        cachedTeamIdentifier
    }

    private static func resolveTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            logger.error("SecCodeCopySelf failed to resolve the running process's code object")
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode
        else {
            logger.error("SecCodeCopyStaticCode failed to resolve the running process's static code")
            return nil
        }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
            let signingInfo = info as? [String: Any]
        else {
            logger.error("SecCodeCopySigningInformation failed to read the running process's signing info")
            return nil
        }

        // The key is absent (not present-but-nil) for unsigned or ad-hoc
        // signed code, which is an expected outcome in some test-host
        // configurations — not a failure worth logging above `.info`.
        guard let team = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String else {
            logger.info("Running code has no team identifier (unsigned or ad-hoc signed)")
            return nil
        }
        return team
    }
}
