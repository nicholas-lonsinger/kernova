import Foundation

// Host "Copy to Mac" XPC broker contract (issue #424 Phase 2b).
//
// The main app owns the vsock connection but — being neither sandboxed nor
// launchd-managed — cannot register a Mach service (the Phase-0 spike proved
// `NSXPCListener(machServiceName:).resume()` is refused by launchd). So a small
// launchd-managed LaunchAgent (registered via `SMAppService`) vends the
// `…hostrelay` Mach service and acts as a thin pass-through:
//
//   extension --fetchFile--> broker --(forwards on the app's connection)--> main app
//
// The main app connects out to the broker and calls `registerProvider()`,
// exporting its real `ClipboardFileProviderRelay` on that connection; the broker
// captures the connection's `remoteObjectProxy` and forwards each `fetchFile` to
// it. No bytes cross the broker — only `(generation, repIndex)` and a staged
// path; the payload rides the shared app-group container, as in the guest path.

/// The interface the broker exports on its Mach service.
///
/// Inherits `fetchFile` (called by the sandboxed extension) and adds
/// `registerProvider` (called by the main app to nominate itself as the backing
/// relay). One interface serves both callers, so the broker needn't distinguish
/// them by role — each calls only the method it needs.
@objc public protocol ClipboardFileProviderBroker: ClipboardFileProviderRelay {
    /// Called by the main app to register itself as the backing relay provider.
    ///
    /// The broker captures the calling connection's `remoteObjectProxy` (a
    /// `ClipboardFileProviderRelay`) and forwards each `fetchFile` to it until the
    /// connection invalidates.
    func registerProvider()
}

/// Identity + code-signing requirements for the broker's three XPC legs,
/// in one place so every peer pins the same strings (one source of truth).
public enum ClipboardFileProviderBrokerIdentity {
    /// The broker LaunchAgent's bundle identifier.
    public static let brokerBundleIdentifier = "app.kernova.clipboard.relay"

    /// The plist name passed to `SMAppService.agent(plistName:)`; the bundled
    /// LaunchAgent plist declares `MachServices = { <host Mach name> }`.
    public static let brokerLaunchAgentPlistName = "app.kernova.clipboard.relay.plist"

    /// The Mach service the broker vends (the host direction's relay name).
    public static var machServiceName: String { ClipboardFileProviderConfig.host.machServiceName }

    /// Requirement the main app and the extension apply to the broker connection,
    /// so a rogue process can't impersonate the broker.
    ///
    /// `anchor apple generic` + the team OU holds for both Apple Development and
    /// Developer ID signing (team `8MT4P4GZL2` is the cert OU, not the CN
    /// parenthetical — a known footgun).
    public static let brokerRequirement =
        "identifier \"app.kernova.clipboard.relay\" "
        + "and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"8MT4P4GZL2\""

    /// Requirement the broker applies to incoming connections: a Kernova-team
    /// peer that is either the main app or the host File Provider extension.
    public static let clientRequirement =
        "anchor apple generic "
        + "and certificate leaf[subject.OU] = \"8MT4P4GZL2\" "
        + "and (identifier \"app.kernova\" or identifier \"app.kernova.clipboard.fileprovider\")"
}
