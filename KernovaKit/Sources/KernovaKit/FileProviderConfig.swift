import FileProvider
import Foundation

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
// `FileManager.getFileProviderServicesForItem(at:)` and exports the relay so the
// extension can call back at `fetchContents`, and a per-direction Darwin
// notification is the reconnect doorbell. There is no Mach service.
//
// The team-ID-prefixed app group (`8MT4P4GZL2.app.kernova`) is retained for the
// shared staging container: macOS grants a `<TeamID>.*` app group implicitly to
// a team-signed process, so it works under the project's profile-less manual
// signing ("Option A") — the guest agent must run in any VM without a
// device-limited provisioning profile, and a plain `group.*` group would demand
// one. (The team prefix was never about Mach-service lookup, which is now gone.)
//
// Guest and host deliberately share the registered app group but use distinct
// service names, domain identifiers, container subpaths, and Darwin doorbell
// names, so a dev Mac running both the guest agent (host-local) and the main app
// never collides (in production they're separate machines / OS instances).

/// Per-direction configuration for the clipboard File Provider transport.
public struct FileProviderConfig: Sendable {
    /// App group shared by the container app and its sandboxed extension.
    ///
    /// Scopes the shared staging container the owner writes into and the
    /// extension APFS-clones out of. Team-ID-prefixed so macOS grants it
    /// implicitly under profile-less manual signing (a plain `group.*` group would
    /// require a provisioning profile); no longer used for any Mach-service lookup.
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

    /// Builds a code-signing requirement pinning a specific bundle `identifier` to
    /// the Kernova team.
    ///
    /// `anchor apple generic` + the team OU holds for both Apple Development and
    /// Developer ID signing — and team `8MT4P4GZL2` is the certificate OU, not the
    /// CN parenthetical (a known footgun). Both peer pins below share this shape, so
    /// the anchor/team clause lives here once and can't drift between them.
    private static func teamSignedRequirement(identifier: String) -> String {
        "identifier \"\(identifier)\" "
            + "and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"8MT4P4GZL2\""
    }

    /// Code-signing requirement matching the main Kernova app (`app.kernova`).
    ///
    /// The host extension pins this on the connecting owner so a rogue process
    /// can't impersonate the app that exports the relay.
    public static let mainAppRequirement = teamSignedRequirement(identifier: "app.kernova")

    /// Code-signing requirement matching the host File Provider extension
    /// (`app.kernova.fileprovider`).
    ///
    /// The main app pins this on its `getFileProviderConnection` control
    /// connection so it only exports the relay to the genuine Kernova-team
    /// extension.
    public static let hostExtensionRequirement =
        teamSignedRequirement(identifier: "app.kernova.fileprovider")

    /// Host→guest: the guest agent serves the host's copied file to the guest
    /// (issue #376).
    public static let guest = FileProviderConfig(
        appGroupIdentifier: "8MT4P4GZL2.app.kernova",
        serviceName: NSFileProviderServiceName("app.kernova.clipboard.guest.relay"),
        reconnectNotificationName: "app.kernova.clipboard.guest.reconnect",
        domainIdentifier: "kernova-clipboard",
        domainDisplayName: "Kernova Clipboard",
        containerDirectoryName: "FileProvider",
        loggerSubsystem: "app.kernova.macosagent",
        extensionLoggerSubsystem: "app.kernova.macosagent.fileprovider",
        ownerCodeSigningRequirement: nil,
        extensionCodeSigningRequirement: nil)

    /// Guest→host: the main app serves the guest's copied file to the Mac
    /// ("Copy to Mac", issue #424).
    ///
    /// Distinct service/domain/subpath/doorbell from the guest so both can
    /// coexist on a dev Mac; reuses the same registered app group.
    public static let host = FileProviderConfig(
        appGroupIdentifier: "8MT4P4GZL2.app.kernova",
        serviceName: NSFileProviderServiceName("app.kernova.clipboard.host.relay"),
        reconnectNotificationName: "app.kernova.clipboard.host.reconnect",
        domainIdentifier: "kernova-clipboard-host",
        domainDisplayName: "Kernova Clipboard (Mac)",
        containerDirectoryName: "FileProviderHost",
        loggerSubsystem: "app.kernova",
        extensionLoggerSubsystem: "app.kernova.fileprovider",
        ownerCodeSigningRequirement: FileProviderConfig.mainAppRequirement,
        extensionCodeSigningRequirement: FileProviderConfig.hostExtensionRequirement)
}
