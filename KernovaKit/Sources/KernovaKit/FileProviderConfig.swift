import FileProvider
import Foundation
import os

// Direction configuration for the shared clipboard File Provider machinery
// (issues #376 guest / #424 host / #460 servicing migration).
//
// The guest agent (host→guest paste) and the main app (guest→host "Copy to
// Mac") run the *same* domain host + extension logic; only the addressing and
// logging differ. This config carries those direction-specific values so one
// implementation serves both, with the constants for each direction defined
// once here (the single source of truth).
//
// Host↔extension IPC uses the canonical `NSFileProviderServicing` anonymous-XPC
// pattern (#460): the extension vends a listener endpoint under a per-direction
// `NSFileProviderServiceName`, the owner connects via
// `NSFileProviderManager.getService(named:for:)` (identifier-based — the
// path-based `FileManager` form needs filesystem access to the domain root,
// which the sandboxed host app doesn't have, #539) and exports the relay so the
// extension can call back at `fetchContents`, and a per-direction Darwin
// notification is the reconnect doorbell. There is no Mach service.
//
// The app group scopes the shared staging container. Its identifier is
// per-build-configuration (the `KERNOVA_APP_GROUP` build setting): Debug uses a
// Team-ID-prefixed group (`$(DEVELOPMENT_TEAM).app.kernova`) that macOS grants
// silent container access to with no provisioning profile (macOS 15 app-group
// protection, criterion C), and Release uses the canonical iOS-style
// `group.app.kernova` authorized by an embedded provisioning profile. Each
// executable resolves its value from the Info.plist via
// `KernovaAppGroup.identifier()`, which `host()` / `guest()` read by default.
// Because Debug is Team-ID-prefixed, the agent no longer hits the one-time macOS
// "access data from other apps" consent prompt inside an unregistered guest VM.
//
// Guest and host deliberately share the app group but use distinct service names,
// domain identifiers, container subpaths, and Darwin doorbell names, so a dev Mac
// running both the guest agent (host-local) and the main app never collides (in
// production they're separate machines / OS instances).

/// Per-direction configuration for the clipboard File Provider transport.
public struct FileProviderConfig: Sendable {
    /// App group shared by the container app and its sandboxed extension.
    ///
    /// Scopes the shared staging container the owner writes into and the
    /// extension APFS-clones out of. Per-build-configuration (see the file
    /// header); resolved from the Info.plist by `host()` / `guest()`. No longer
    /// used for any Mach-service lookup.
    public let appGroupIdentifier: String

    /// The `NSFileProviderServiceName` the extension vends its anonymous XPC
    /// endpoint under and the owner selects when connecting.
    ///
    /// Reverse-DNS by convention; per-direction so a dev Mac running both host
    /// and guest never crosses wires.
    public let serviceName: NSFileProviderServiceName

    /// The Darwin notification name the extension posts (reconnect doorbell) and
    /// the owner observes to re-establish the control connection.
    ///
    /// Darwin names are a flat global namespace with no app-group prefix (that
    /// rule is Mach-service-only); per-direction, reverse-DNS by convention.
    public let reconnectNotificationName: String

    /// Stable File Provider domain identifier (no `/` or `:`, which the
    /// framework reserves for path separators / domain qualifiers).
    public let domainIdentifier: String

    /// User-visible domain name shown as the Finder location's root folder.
    public let domainDisplayName: String

    /// Subdirectory under the app-group container for this direction's manifest
    /// and staging, so guest and host never collide on a shared dev Mac.
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
    /// The host pins the main app (the only process allowed to export the relay);
    /// the guest leaves it `nil` — per-VM vsock auth is tracked separately (#145)
    /// and both guest processes run inside the same VM.
    public let ownerCodeSigningRequirement: String?

    /// Code-signing requirement the **owner** pins on the **extension** for its
    /// `getFileProviderConnection` control connection, or `nil` to skip.
    ///
    /// The host pins the host File Provider extension; the guest leaves it `nil`
    /// (same rationale as `ownerCodeSigningRequirement`).
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
    /// The single construction point for domain identity: the domain host
    /// registers the domain this returns, and the servicing connector's
    /// identifier-based `getService(named:for:)` lookup must resolve the same
    /// domain (#539). Each call site constructs a fresh instance rather than
    /// sharing one — `NSFileProviderDomain` is not Sendable, so a shared
    /// instance couldn't cross the connector's `@Sendable` connect closure.
    public func makeDomain() -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainIdentifier),
            displayName: domainDisplayName)
    }

    /// Builds a code-signing requirement pinning a specific bundle `identifier`
    /// to the given `team`.
    ///
    /// `anchor apple generic` + the team OU holds for both Apple Development and
    /// Developer ID signing, so one requirement matches whichever of the two the
    /// peer is actually signed with. `subject.OU` is the certificate field that
    /// carries the team ID — not the CN parenthetical, which is a known footgun
    /// (see `Tools/bootstrap-team.sh`). Both peer pins built by `host()` share
    /// this shape, so the anchor/team clause lives here once and can't drift
    /// between them.
    private static func teamSignedRequirement(identifier: String, team: String) -> String {
        "identifier \"\(identifier)\" "
            + "and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Host→guest: the guest agent serves the host's copied file to the guest
    /// (issue #376).
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
    /// ("Copy to Mac", issue #424).
    ///
    /// Distinct service/domain/subpath/doorbell from the guest so both can
    /// coexist on a dev Mac; reuses the same app group.
    ///
    /// - Parameters:
    ///   - appGroupIdentifier: the shared container's app group; defaults to
    ///     the running executable's configured value.
    ///   - teamIdentifier: the team the host↔extension XPC peer requirements
    ///     pin to; defaults to the running executable's own signing team
    ///     (#476) so the pin floats with whoever cloned and signed the
    ///     build, rather than a hardcoded team. Pinning the peer to *my own*
    ///     team is correct because the host app and its embedded
    ///     `KernovaFileProvider.appex` are always co-signed by the same team —
    ///     an invariant Xcode's `ValidateEmbeddedBinary` build phase enforces
    ///     (it fails the build if a host and an embedded binary carry
    ///     different Team IDs), so the two processes always resolve the same
    ///     value here. `nil` (unsigned/ad-hoc, not the real signed host path)
    ///     skips peer validation.
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
