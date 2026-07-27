import FileProvider
import Foundation
import os

// Direction configuration for the shared clipboard File Provider machinery: the
// guest agent (host→guest paste) and the main app (guest→host "Copy to Mac") run
// the same domain host + extension logic, differing only in the values below.
// Both directions share the app group but must keep distinct service names,
// domain identifiers, container subpaths, and doorbell names so a dev Mac running
// both never collides. The app group is per-build-configuration
// (`KERNOVA_APP_GROUP`); renaming Debug's Team-ID-prefixed group breaks the
// profile-less signing that grants it silent container access.

/// Per-direction configuration for the clipboard File Provider transport.
public struct FileProviderConfig: Sendable {
    /// App group scoping the staging container the owner writes into and the
    /// extension APFS-clones out of.
    public let appGroupIdentifier: String

    /// The `NSFileProviderServiceName` the extension vends its anonymous XPC
    /// endpoint under and the owner selects when connecting.
    public let serviceName: NSFileProviderServiceName

    /// The Darwin notification name the extension posts (reconnect doorbell) and
    /// the owner observes to re-establish the control connection.
    ///
    /// Darwin names are a flat global namespace and take no app-group prefix —
    /// that rule is Mach-service-only.
    public let reconnectNotificationName: String

    /// Stable File Provider domain identifier (no `/` or `:`, which the
    /// framework reserves for path separators / domain qualifiers).
    public let domainIdentifier: String

    /// User-visible domain name shown as the Finder location's root folder.
    public let domainDisplayName: String

    /// Subdirectory under the app-group container for this direction's manifest
    /// and staging.
    public let containerDirectoryName: String

    /// `KernovaLogger` subsystem for the domain host + relay service (runs in
    /// the container app: the guest agent or the main app).
    public let loggerSubsystem: String

    /// `os.Logger` subsystem for the sandboxed extension (a separate process).
    public let extensionLoggerSubsystem: String

    /// Code-signing requirement the **extension** pins on the connecting
    /// **owner** in `shouldAcceptNewConnection`, or `nil` to skip peer
    /// validation.
    ///
    /// The host pins the main app, the only process allowed to export the relay;
    /// the guest leaves it `nil` — both guest processes run inside the same VM.
    public let ownerCodeSigningRequirement: String?

    /// Code-signing requirement the **owner** pins on the **extension** for its
    /// `getFileProviderConnection` control connection, or `nil` to skip.
    public let extensionCodeSigningRequirement: String?

    /// Creates a direction config from its addressing and logging values.
    public init(
        appGroupIdentifier: String,
        serviceName: NSFileProviderServiceName,
        reconnectNotificationName: String,
        domainIdentifier: String,
        domainDisplayName: String,
        containerDirectoryName: String,
        loggerSubsystem: String,
        extensionLoggerSubsystem: String,
        ownerCodeSigningRequirement: String?,
        extensionCodeSigningRequirement: String?
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.serviceName = serviceName
        self.reconnectNotificationName = reconnectNotificationName
        self.domainIdentifier = domainIdentifier
        self.domainDisplayName = domainDisplayName
        self.containerDirectoryName = containerDirectoryName
        self.loggerSubsystem = loggerSubsystem
        self.extensionLoggerSubsystem = extensionLoggerSubsystem
        self.ownerCodeSigningRequirement = ownerCodeSigningRequirement
        self.extensionCodeSigningRequirement = extensionCodeSigningRequirement
    }

    private static let logger = Logger(subsystem: "app.kernova", category: "FileProviderConfig")

    /// Builds this direction's File Provider domain.
    ///
    /// `NSFileProviderDomain` is not `Sendable`, so each call site builds a fresh
    /// instance rather than sharing one across the connector's `@Sendable`
    /// connect closure.
    public func makeDomain() -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainIdentifier),
            displayName: domainDisplayName)
    }

    /// Builds a code-signing requirement pinning a specific bundle `identifier`
    /// to the given `team`.
    ///
    /// `anchor apple generic` + the team OU holds for both Apple Development and
    /// Developer ID signing, so one requirement matches whichever the peer is
    /// signed with. `subject.OU` is the certificate field carrying the team ID —
    /// not the CN parenthetical, a known footgun (`Tools/bootstrap-team.sh`).
    private static func teamSignedRequirement(identifier: String, team: String) -> String {
        "identifier \"\(identifier)\" "
            + "and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Host→guest: the guest agent serves the host's copied file to the guest.
    ///
    /// - Parameter appGroupIdentifier: the shared container's app group;
    ///   defaults to the running executable's configured value.
    /// - Returns: a guest-direction config.
    public static func guest(
        appGroupIdentifier: String = KernovaAppGroup.identifier()
    ) -> FileProviderConfig {
        FileProviderConfig(
            appGroupIdentifier: appGroupIdentifier,
            serviceName: NSFileProviderServiceName("app.kernova.clipboard.guest.relay"),
            reconnectNotificationName: "app.kernova.clipboard.guest.reconnect",
            domainIdentifier: "kernova-clipboard",
            domainDisplayName: "Kernova Clipboard",
            containerDirectoryName: "FileProvider",
            loggerSubsystem: "app.kernova.macosagent",
            extensionLoggerSubsystem: "app.kernova.macosagent.fileprovider",
            ownerCodeSigningRequirement: nil,
            extensionCodeSigningRequirement: nil)
    }

    /// Guest→host: the main app serves the guest's copied file to the Mac
    /// ("Copy to Mac").
    ///
    /// - Parameters:
    ///   - appGroupIdentifier: the shared container's app group; defaults to
    ///     the running executable's configured value.
    ///   - teamIdentifier: the team the XPC peer requirements pin to; defaults
    ///     to the running executable's own signing team, which the extension
    ///     always shares (Xcode's `ValidateEmbeddedBinary` phase enforces it).
    ///     `nil` (unsigned/ad-hoc) skips peer validation.
    /// - Returns: a host-direction config.
    public static func host(
        appGroupIdentifier: String = KernovaAppGroup.identifier(),
        teamIdentifier: String? = KernovaCodeSignature.teamIdentifier()
    ) -> FileProviderConfig {
        let ownerRequirement: String?
        let extensionRequirement: String?
        if let teamIdentifier {
            ownerRequirement = teamSignedRequirement(identifier: "app.kernova", team: teamIdentifier)
            extensionRequirement = teamSignedRequirement(
                identifier: "app.kernova.fileprovider", team: teamIdentifier)
        } else {
            logger.warning(
                "No team identifier resolved for the running code; skipping host↔extension XPC peer pin"
            )
            ownerRequirement = nil
            extensionRequirement = nil
        }
        return FileProviderConfig(
            appGroupIdentifier: appGroupIdentifier,
            serviceName: NSFileProviderServiceName("app.kernova.clipboard.host.relay"),
            reconnectNotificationName: "app.kernova.clipboard.host.reconnect",
            domainIdentifier: "kernova-clipboard-host",
            domainDisplayName: "Kernova Clipboard (Mac)",
            containerDirectoryName: "FileProviderHost",
            loggerSubsystem: "app.kernova",
            extensionLoggerSubsystem: "app.kernova.fileprovider",
            ownerCodeSigningRequirement: ownerRequirement,
            extensionCodeSigningRequirement: extensionRequirement)
    }
}
