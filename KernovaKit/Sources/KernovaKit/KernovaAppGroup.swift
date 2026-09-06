import Foundation
import Security

/// The app group the app and its command-line tool share, resolved from the
/// running process's own signature.
///
/// The group ID is team-prefixed (`<team>.app.kernova`) because
/// `containermanagerd` grants a group container only to a signature whose team
/// prefixes the ID. Neither side spells the prefix: each reads the
/// `com.apple.security.application-groups` array its own signature carries, so
/// the value follows whatever identity the build was signed with and a build
/// signed with none resolves `nil` — the capability is then absent rather than
/// broken.
public enum KernovaAppGroup {
    /// What both entitlement files claim behind `$(TeamIdentifierPrefix)`.
    public static let identifierSuffix = "app.kernova"

    /// The command socket's leaf name inside the group container.
    public static let socketFileName = "kernova.sock"

    /// What the command-line tool is called, on disk and on a command line.
    public static let commandLineToolName = "kernova"

    private static let entitlementKey = "com.apple.security.application-groups"

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "KernovaAppGroup")

    /// The entry in `groups` naming this app's group, `nil` when none does.
    ///
    /// A match is a team prefix followed by ``identifierSuffix``: everything
    /// after the first `.` must equal the suffix exactly, so an unprefixed
    /// `app.kernova` — which no container is granted for — is not one.
    public static func identifier(fromEntitlementGroups groups: [String]) -> String? {
        groups.first { group in
            guard let separator = group.firstIndex(of: ".") else { return false }
            return group[group.index(after: separator)...] == identifierSuffix
        }
    }

    /// The group this process's own signature claims, `nil` when it claims
    /// none.
    ///
    /// Read once per process; the answer cannot change while it runs.
    public static func resolvedIdentifier() -> String? { resolved }

    /// The group container's URL, `nil` when this build resolves no group.
    public static func containerURL() -> URL? {
        guard let identifier = resolvedIdentifier() else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Where the command socket lives, `nil` when there is no container to
    /// hold it.
    public static func socketURL() -> URL? {
        containerURL()?.appendingPathComponent(socketFileName, isDirectory: false)
    }

    /// The command socket's filesystem path, which is the form the socket calls
    /// take.
    ///
    /// Both ends read it here, so neither can bind or dial a path the other
    /// spelled differently.
    public static func socketPath() -> String? {
        socketURL()?.withUnsafeFileSystemRepresentation { representation in
            representation.map { String(cString: $0) }
        }
    }

    private static let resolved: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, entitlementKey as CFString, nil),
            let groups = value as? [String]
        else {
            logger.warning(
                "This build's signature claims no application group — the app-group container, and everything that lives in it, is unavailable"
            )
            return nil
        }
        guard let identifier = identifier(fromEntitlementGroups: groups) else {
            logger.warning(
                "This build's signature claims no team-prefixed '\(identifierSuffix, privacy: .public)' group (claims \(groups.joined(separator: ", "), privacy: .public)) — the app-group container is unavailable"
            )
            return nil
        }
        return identifier
    }()
}
