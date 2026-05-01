import Foundation

/// Whether the guest agent is installed and current relative to what the host bundles.
///
/// `VsockClipboardService` derives this from the agent version reported in the
/// `Hello` frame against `KernovaGuestAgentInfo.bundledVersion`.
/// `SpiceClipboardService` reports `.waiting` until handshake and `.current`
/// afterwards — Linux guests install spice-vdagent themselves so there is no
/// host-side install/update flow to drive.
enum AgentStatus: Equatable, Sendable {

    /// No `Hello` has been received yet. The guest agent may not be installed,
    /// or the VM may simply still be booting. The UI uses this state to offer
    /// an install affordance for macOS guests with clipboard sharing enabled.
    case waiting

    /// The guest agent is connected and its version matches what the host bundles.
    /// `version` is the guest-reported string (`Hello.agent_info.agent_version`).
    case current(version: String)

    /// The guest agent is connected but reports a version older than what the
    /// host bundles. The UI uses this state to offer an update affordance.
    case outdated(installed: String, bundled: String)
}

/// Common surface shared by every clipboard transport.
///
/// Two implementations exist:
/// - `SpiceClipboardService` — Linux guests, runs the SPICE agent protocol over a
///   `VZVirtioConsolePortConfiguration`-backed pipe pair.
/// - `VsockClipboardService` — macOS guests, runs the Kernova clipboard protocol
///   over a `VZVirtioSocketDevice`-backed `VsockChannel`.
///
/// Both implementations are `@Observable` classes so consumers can observe
/// `clipboardText` and `isConnected` through the existential type without losing
/// SwiftUI / `withObservationTracking` integration: the `@Observable` macro
/// installs the registrar on the concrete type, so reading or writing through
/// the protocol witness still fires observation.
@MainActor
protocol ClipboardServicing: AnyObject {

    /// Bidirectional clipboard buffer. Set by the user (via the clipboard window)
    /// to seed an outbound grab; updated by the implementation when the guest
    /// pushes new content.
    var clipboardText: String { get set }

    /// `true` once the implementation has completed its handshake with the guest.
    var isConnected: Bool { get }

    /// Whether the connected guest agent is missing, current, or outdated.
    /// Drives install/update affordances in the clipboard window and sidebar.
    var agentStatus: AgentStatus { get }

    /// Begins protocol I/O with the guest.
    func start()

    /// Stops protocol I/O. Idempotent.
    func stop()

    /// Announces the current `clipboardText` to the guest if it has changed since
    /// the last successful announcement. Called by the clipboard window when it
    /// loses focus.
    func grabIfChanged()
}
