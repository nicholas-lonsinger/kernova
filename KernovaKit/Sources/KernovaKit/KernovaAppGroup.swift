import CryptoKit
import Foundation
import KernovaLogging
import Security

/// The app group the app and its command-line tool share, resolved from the
/// running process's own signature.
///
/// The group ID is team-prefixed (`<team>.app.kernova`), and neither side
/// spells the prefix: each reads the `com.apple.security.application-groups`
/// array its own signature carries, so the value follows whatever identity the
/// build was signed with and a build signed with none resolves `nil` — the
/// capability is then absent rather than broken.
public enum KernovaAppGroup {
    /// What both entitlement files claim behind `$(TeamIdentifierPrefix)`.
    public static let identifierSuffix = "app.kernova"

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

    /// The command socket of the copy of Kernova at `appBundle`, as the
    /// filesystem path the socket calls take, `nil` when there is no container
    /// to hold it.
    ///
    /// Every copy answers on its own socket, named for its bundle's resolved
    /// path: the app passes its own bundle and the tool the bundle it is
    /// inside, so the two ends name one socket and no two copies share one.
    public static func socketPath(forAppBundle appBundle: URL) -> String? {
        guard let container = containerURL() else { return nil }
        return socketPath(forAppBundle: appBundle, in: container)
    }

    /// ``socketPath(forAppBundle:)`` inside `container`.
    static func socketPath(forAppBundle appBundle: URL, in container: URL) -> String? {
        let bundlePath = appBundle.resolvingSymlinksInPath().standardizedFileURL.path
        let name = SHA256.hash(data: Data(bundlePath.utf8))
            .prefix(socketNameDigestBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return container.appendingPathComponent("\(name).sock", isDirectory: false)
            .withUnsafeFileSystemRepresentation { representation in
                representation.map { String(cString: $0) }
            }
    }

    /// Leading bytes of the bundle-path digest a socket's name carries: enough
    /// to keep every copy on a Mac apart, and few enough that the whole path
    /// fits `sun_path` under a long account name.
    private static let socketNameDigestBytes = 6

    private static let resolved: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, entitlementKey as CFString, nil),
            let groups = value as? [String]
        else {
            #log(
                logger, .warning,
                "This build's signature claims no application group — the app-group container, and everything that lives in it, is unavailable"
            )
            return nil
        }
        guard let identifier = identifier(fromEntitlementGroups: groups) else {
            #log(
                logger, .warning,
                "This build's signature claims no team-prefixed '\(identifierSuffix, privacy: .public)' group (claims \(groups.joined(separator: ", "), privacy: .public)) — the app-group container is unavailable"
            )
            return nil
        }
        return identifier
    }()
}
