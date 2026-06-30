import Foundation
import KernovaKit

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

    /// The clipboard transfer currently being shown, or `nil` when none is.
    /// Drives the clipboard window's bottom progress bar and the toolbar button's
    /// under-bar; both read this single source so they cannot disagree. Set once a
    /// transfer crosses the reveal delay, cleared on every terminal state.
    /// `nil` for transports without byte-level progress (the default below).
    var transferProgress: ClipboardTransferProgress? { get }

    /// Stops protocol I/O. Idempotent.
    func stop()

    /// Announces the current `clipboardContent` to the guest if it has changed
    /// since the last successful announcement. Called by the clipboard window
    /// when it loses focus, and immediately after a paste/drop gesture.
    func grabIfChanged()

    /// Empties the buffer (the window's "Clear" gesture) and resets the
    /// outbound dedup state.
    ///
    /// Resetting the dedup is the reason this isn't just `clipboardContent =
    /// .empty`: otherwise re-copying the just-cleared content would be
    /// suppressed by `grabIfChanged()` as "unchanged" and silently never reach
    /// the guest — mirrors the `lastGrabbedDigest`/`lastGrabbedText` reset the
    /// inbound path already performs after a round-trip.
    func clearBuffer()

    /// Pulls the representations the clipboard window renders richly (text,
    /// inline RTF, images up to a size limit) for a lazily-offered guest payload,
    /// updating `clipboardContent` as they land. The window calls it when it
    /// displays a guest offer. Default no-op: transports that deliver content
    /// eagerly (SPICE text) have nothing to pull.
    func materializeForPreview() async

    /// Prepares the items to write to the host pasteboard for "Copy to Mac".
    ///
    /// Inline, preview, and directory representations are pulled eagerly and
    /// returned resolved; a single plain file representation is published as a
    /// lazy host File Provider placeholder (materialized on read via
    /// `fetchContents`, no deadline) or, when the File Provider is off, deferred
    /// to a size-capped synchronous paste (`.lazyFile`); files that can't be
    /// served are reported as `.droppedFile`. Default maps `clipboardContent`'s
    /// representations to `.resolved` for eager transports (SPICE text).
    func materializeForCopy() async -> [CopyToMacItem]
}

/// One item "Copy to Mac" places on the host pasteboard.
///
/// `materializeForCopy()` classifies each offered representation into one of
/// these; the clipboard window turns them into `NSPasteboardItem`s. A directory
/// or inline payload is `.resolved` (bytes/URL in hand); the single lazy-eligible
/// plain file is either `.resolved` with a File Provider placeholder URL or
/// `.lazyFile` (pulled on paste when the File Provider is off); anything that
/// can't be served is `.droppedFile`.
enum CopyToMacItem: Sendable {
    /// A representation whose bytes are already resolved — an inline/preview rep
    /// pulled eagerly, an extracted directory, or a File Provider placeholder URL.
    case resolved(ClipboardContent.Representation)
    /// The single plain file rep to serve lazily at paste time when the host File
    /// Provider is off: pulled + staged on demand within the OS paste deadline,
    /// addressed by its offer coordinates so the paste-time provider can request it.
    case lazyFile(generation: UInt64, repIndex: Int, uti: String, filename: String)
    /// A file payload that couldn't be served — the `reason` drives the user-facing
    /// message (and, for the over-cap case, points the user at enabling the File
    /// Provider, which lifts the cap).
    case droppedFile(CopyToMacDropReason)
}

/// Why a "Copy to Mac" file payload couldn't be placed on the host pasteboard.
///
/// Distinguished so the clipboard window can show a specific, actionable message
/// rather than a generic failure.
enum CopyToMacDropReason: Sendable, Equatable {
    /// Over the deadline-safe size cap while the host File Provider is off —
    /// enabling it routes the file lazily (no cap, no deadline).
    case tooLargeWithoutFileProvider
    /// More than one file was offered; "Copy to Mac" serves a single file (D2).
    case multipleFiles
    /// An eager pull (a directory or image file) failed.
    case pullFailed
}

extension ClipboardServicing {
    func materializeForPreview() async {}
    func materializeForCopy() async -> [CopyToMacItem] {
        clipboardContent.representations.map { .resolved($0) }
    }

    /// Transports without byte-level progress (SPICE text, fakes) never show a
    /// transfer bar.
    var transferProgress: ClipboardTransferProgress? { nil }
}
