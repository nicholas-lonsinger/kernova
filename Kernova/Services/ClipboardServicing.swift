import Foundation
import KernovaProtocol

/// Common surface shared by every clipboard transport.
///
/// Two implementations exist:
/// - `SpiceClipboardService` — Linux guests, runs the SPICE agent protocol over a
///   `VZVirtioConsolePortConfiguration`-backed pipe pair. Text-only: the SPICE
///   transport carries just the UTF-8 representation of `clipboardContent`
///   until the rich-format follow-up to issue #112 lands.
/// - `VsockClipboardService` — macOS guests, runs the Kernova clipboard protocol
///   over a `VZVirtioSocketDevice`-backed `VsockChannel`. Carries every
///   representation of `clipboardContent`.
///
/// Both implementations are `@Observable` classes so consumers can observe
/// `clipboardContent`, `isConnected`, and `lastTransferIssue` through the
/// existential type without losing `withObservationTracking` integration: the
/// `@Observable` macro installs the registrar on the concrete type, so reading
/// or writing through the protocol witness still fires observation.
///
/// `AgentStatus` is **not** part of this protocol. For macOS guests the agent
/// install/version state lives on `VsockControlService` (the always-on control
/// channel, independent of clipboard sharing). `SpiceClipboardService` exposes
/// its own `agentStatus` property directly. The single read site for the UI is
/// `VMInstance.agentStatus`, which dispatches by guest OS.
@MainActor
protocol ClipboardServicing: AnyObject {
    /// Bidirectional clipboard buffer: the ordered UTI-tagged representations
    /// of one logical pasteboard item. Set by the user (via the clipboard
    /// window) to seed an outbound grab; updated by the implementation when
    /// the guest pushes new content.
    var clipboardContent: ClipboardContent { get set }

    /// `true` once the implementation has completed its handshake with the guest.
    var isConnected: Bool { get }

    /// `true` when the transport carries arbitrary UTI-tagged representations;
    /// `false` when it is limited to plain text (SPICE, until the issue #112
    /// follow-up). The window uses this to gate non-text intake with a clear
    /// message instead of accepting content that would silently never send.
    var supportsBinaryRepresentations: Bool { get }

    /// Most recent user-visible transfer problem, or `nil` when healthy.
    /// Set when an outbound payload exceeds the transport limit or the peer
    /// reports a clipboard error; cleared by the next successful transfer.
    /// The window surfaces it as a transient status message.
    var lastTransferIssue: ClipboardTransferIssue? { get }

    /// Stops protocol I/O. Idempotent.
    func stop()

    /// Announces the current `clipboardContent` to the guest if it has changed
    /// since the last successful announcement. Called by the clipboard window
    /// when it loses focus, and immediately after a paste/drop gesture.
    func grabIfChanged()
}
