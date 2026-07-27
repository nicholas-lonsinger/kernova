import Foundation
import KernovaKit

/// Common surface shared by every clipboard transport.
///
/// `SpiceClipboardService` (Linux guests) carries only the UTF-8 representation
/// of `clipboardContent`; `VsockClipboardService` (macOS guests) carries every
/// representation. Both implementations must be `@Observable` classes: the macro
/// installs the registrar on the concrete type, so reading or writing through the
/// protocol witness still fires observation.
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
    /// `false` when it is limited to plain text (SPICE).
    ///
    /// The window gates non-text intake on this rather than accepting content
    /// that would silently never send.
    var supportsBinaryRepresentations: Bool { get }

    /// `true` when a copied folder should cross as a File Provider placeholder
    /// *tree* (walked on demand, no eager archive) rather than being archived at
    /// intake — the mutually-negotiated `clipboard.dirtree.v1` capability.
    ///
    /// `false` for SPICE and until the guest's capability is known.
    var supportsDirectoryTree: Bool { get }

    /// Most recent user-visible transfer problem, or `nil` when healthy.
    ///
    /// Set when an outbound payload exceeds the transport limit or the peer
    /// reports a clipboard error; cleared by the next successful transfer.
    var lastTransferIssue: ClipboardTransferIssue? { get }

    /// The clipboard transfer currently being shown, or `nil` when none is.
    ///
    /// Aggregate per *operation*, never per file: a multi-file paste fills one bar
    /// once. Set once the operation crosses the reveal delay, cleared at its
    /// terminal. `nil` for transports without byte-level progress.
    var transferProgress: ClipboardProgressSnapshot? { get }

    /// Monotonically increases each time a **new inbound guest offer** is
    /// published to `clipboardContent` — not on our own outbound writes, and not
    /// on the per-representation preview/copy materialization of an
    /// already-published offer.
    var inboundOfferSeq: UInt64 { get }

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
    /// .empty`: otherwise re-copying the just-cleared content would be suppressed
    /// by `grabIfChanged()` as "unchanged" and silently never reach the guest.
    func clearBuffer()

    /// Pulls the representations the clipboard window renders richly (text,
    /// inline RTF, images up to a size limit) for a lazily-offered guest payload,
    /// updating `clipboardContent` as they land.
    ///
    /// Default no-op: transports that deliver content eagerly have nothing to pull.
    func materializeForPreview() async

    /// Prepares the items to write to the host pasteboard for "Copy to Mac".
    ///
    /// Inline, preview, and directory representations are pulled eagerly and
    /// returned resolved; every lazy-eligible plain file representation becomes a
    /// `.lazyFile` routed at paste time; files that can't be served are reported
    /// as `.droppedFile`.
    func materializeForCopy() async -> [CopyToMacItem]
}

/// One item "Copy to Mac" places on the host pasteboard.
enum CopyToMacItem: Sendable {
    /// A representation whose bytes are already resolved — an inline/preview rep
    /// pulled eagerly, or an extracted directory.
    case resolved(ClipboardContent.Representation)
    /// A plain file rep served lazily at paste time, addressed by its offer
    /// coordinates so the paste-time provider can request it.
    case lazyFile(generation: UInt64, repIndex: Int, uti: String, filename: String)
    /// A file payload that couldn't be served — the `reason` drives the
    /// user-facing message.
    case droppedFile(CopyToMacDropReason)
}

/// Why a "Copy to Mac" file payload couldn't be placed on the host pasteboard.
enum CopyToMacDropReason: Sendable, Equatable {
    /// The plain-file set's total is over the deadline-safe size cap while the
    /// host File Provider is off — enabling it routes the files lazily (no cap,
    /// no deadline). All-or-nothing: the whole set is refused together.
    case tooLargeWithoutFileProvider
    /// An eager pull (a directory or image file) failed.
    case pullFailed
}

extension ClipboardServicing {
    func materializeForPreview() async {}
    func materializeForCopy() async -> [CopyToMacItem] {
        clipboardContent.representations.map { .resolved($0) }
    }

    /// Transports without byte-level progress never show a transfer bar.
    var transferProgress: ClipboardProgressSnapshot? { nil }

    /// Transports that never receive report no inbound offers.
    var inboundOfferSeq: UInt64 { 0 }
}
