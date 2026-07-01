import Foundation

// Host `…xpc` XPC contract (issues #424 / launch-at-login agent).
//
// The main Kernova app is a launchd-managed background agent (it ships a
// LaunchAgent plist that declares `MachServices = { …xpc }`), so it vends
// the `…xpc` Mach service itself — the SMAppService broker that #424
// introduced (when the app was neither sandboxed nor launchd-managed) is gone.
//
// One always-on listener multiplexes two callers over the single Mach service:
//
//   • the sandboxed host File Provider extension calls `fetchFile` to pull a
//     "Copy to Mac" payload (it can't open vsock — CLIPBOARD.md §11); and
//   • a freshly-spawned foreground launcher process calls `showUserInterface`
//     to bring the resident agent's GUI forward (the agent rests headless in
//     `.accessory` until summoned).
//
// The listener stays up for the agent's whole lifetime — independent of
// clipboard policy — so a double-click summons the GUI even at login with no VM
// running. The clipboard `fetchFile` backing is registered into it only while a
// VM has clipboard sharing on; before that, `fetchFile` replies
// `serverUnreachable`.

/// The interface the resident agent exports on its `…xpc` Mach service.
///
/// Inherits `fetchFile` (called by the sandboxed extension) and adds
/// `showUserInterface` (called by the launcher). One interface serves both
/// callers — each invokes only the method it needs, mirroring how the extension
/// connects with the `ClipboardFileProviderRelay` subset while the launcher
/// connects with the full `KernovaHostRelay`.
@objc public protocol KernovaHostRelay: ClipboardFileProviderRelay {
    /// Asks the resident agent to bring its GUI forward (morph to `.regular`,
    /// activate, show the library window).
    ///
    /// Connecting to `…xpc` also demand-launches the agent via launchd if
    /// the user force-killed it, so this one call both resurrects and summons.
    /// The reply lets the short-lived launcher confirm delivery before it exits.
    func showUserInterface(reply: @escaping @Sendable () -> Void)
}

/// Identity + code-signing requirements for the host `…xpc` legs, in one
/// place so every peer pins the same strings (one source of truth).
public enum KernovaHostRelayIdentity {
    /// The plist name passed to `SMAppService.agent(plistName:)`.
    ///
    /// The bundled LaunchAgent plist (`Contents/Library/LaunchAgents/app.kernova.plist`)
    /// declares `MachServices = { <host relay Mach name> }` and runs the app's
    /// own executable with `--background`.
    public static let launchAgentPlistName = "app.kernova.plist"

    /// Code-signing requirement matching the main Kernova app (`app.kernova`).
    ///
    /// The host File Provider extension pins this on its relay connection so a
    /// rogue process can't impersonate the app that vends `…xpc`, and the
    /// launcher pins it on its summon connection. `anchor apple generic` + the
    /// team OU holds for both Apple Development and Developer ID signing (team
    /// `8MT4P4GZL2` is the cert OU, not the CN parenthetical — a known footgun).
    public static let mainAppRequirement =
        "identifier \"app.kernova\" "
        + "and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"8MT4P4GZL2\""

    /// Requirement the agent's `…xpc` listener applies to inbound peers: a
    /// Kernova-team peer that is either the main app (the launcher's GUI-summon
    /// leg, and the agent itself) or the host File Provider extension (the
    /// clipboard `fetchFile` leg).
    public static let inboundClientRequirement =
        "anchor apple generic "
        + "and certificate leaf[subject.OU] = \"8MT4P4GZL2\" "
        + "and (identifier \"app.kernova\" or identifier \"app.kernova.clipboard.fileprovider\")"
}
