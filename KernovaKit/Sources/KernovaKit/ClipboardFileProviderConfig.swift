import Foundation

// Direction configuration for the shared clipboard File Provider machinery
// (issues #376 guest / #424 host).
//
// The guest agent (host→guest paste) and the main app (guest→host "Copy to
// Mac") run the *same* domain host + extension logic; only the addressing and
// logging differ. This config carries those direction-specific values so one
// implementation serves both, with the constants for each direction defined
// once here (the single source of truth).
//
// Guest and host deliberately share the registered app group but use distinct
// Mach service names, domain identifiers, and container subpaths, so a dev Mac
// running both the guest agent (host-local) and the main app never collides
// (in production they're separate machines / OS instances).

/// Per-direction configuration for the clipboard File Provider transport.
public struct ClipboardFileProviderConfig: Sendable {
    /// App group shared by the container app and its sandboxed extension.
    ///
    /// Team-ID-prefixed (macOS-style) so macOS grants implicit access without a
    /// device-limited provisioning profile.
    public let appGroupIdentifier: String

    /// The Mach service the relay is vended on and the extension connects to.
    ///
    /// Must be prefixed by `appGroupIdentifier` so the sandboxed extension can
    /// look it up.
    public let machServiceName: String

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

    /// Code-signing requirement the extension pins on its relay connection, or
    /// `nil` to skip peer validation.
    ///
    /// The host pins the main app (which now vends `…xpc` directly as a
    /// launchd agent); the guest leaves it `nil` — per-VM vsock auth is tracked
    /// separately (#145) and the team-prefixed Mach name + app-group lookup
    /// already gate the guest leg.
    public let relayCodeSigningRequirement: String?

    /// Creates a direction config from its addressing and logging values.
    public init(
        appGroupIdentifier: String,
        machServiceName: String,
        domainIdentifier: String,
        domainDisplayName: String,
        containerDirectoryName: String,
        loggerSubsystem: String,
        extensionLoggerSubsystem: String,
        relayCodeSigningRequirement: String?
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.machServiceName = machServiceName
        self.domainIdentifier = domainIdentifier
        self.domainDisplayName = domainDisplayName
        self.containerDirectoryName = containerDirectoryName
        self.loggerSubsystem = loggerSubsystem
        self.extensionLoggerSubsystem = extensionLoggerSubsystem
        self.relayCodeSigningRequirement = relayCodeSigningRequirement
    }

    /// Host→guest: the guest agent serves the host's copied file to the guest
    /// (issue #376).
    ///
    /// Preserves D1a's shipped identifiers verbatim.
    public static let guest = ClipboardFileProviderConfig(
        appGroupIdentifier: "8MT4P4GZL2.app.kernova",
        machServiceName: "8MT4P4GZL2.app.kernova.relay",
        domainIdentifier: "kernova-clipboard",
        domainDisplayName: "Kernova Clipboard",
        containerDirectoryName: "FileProvider",
        loggerSubsystem: "app.kernova.agent",
        extensionLoggerSubsystem: "app.kernova.agent.fileprovider",
        relayCodeSigningRequirement: nil)

    /// Guest→host: the main app serves the guest's copied file to the Mac
    /// ("Copy to Mac", issue #424).
    ///
    /// Distinct Mach/domain/subpath from the guest so both can coexist on a dev
    /// Mac; reuses the same registered app group.
    public static let host = ClipboardFileProviderConfig(
        appGroupIdentifier: "8MT4P4GZL2.app.kernova",
        machServiceName: "8MT4P4GZL2.app.kernova.xpc",
        domainIdentifier: "kernova-clipboard-host",
        domainDisplayName: "Kernova Clipboard (Mac)",
        containerDirectoryName: "FileProviderHost",
        loggerSubsystem: "app.kernova",
        extensionLoggerSubsystem: "app.kernova.clipboard.fileprovider",
        relayCodeSigningRequirement: KernovaHostRelayIdentity.mainAppRequirement)
}
