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

    /// Most recent user-visible transfer problem, or `nil` when healthy.
    ///
    /// Set when an outbound payload exceeds the transport limit or the peer
    /// reports a clipboard error; cleared by the next successful transfer.
    var lastTransferIssue: ClipboardTransferIssue? { get }

    /// Records a problem an *automatic* path produced, for `lastTransferIssue`
    /// to carry.
    ///
    /// A window gesture reports its own outcome inline; a passthrough forward has
    /// no return path, so the issue is the only account it can give. Default
    /// no-op: a transport that never surfaces an issue drops it.
    func reportIssue(_ issue: ClipboardTransferIssue)

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

    /// Reserves a directory for the window to materialize a dropped file promise
    /// into, or `nil` when the transport can't stage one.
    ///
    /// The files stay there for as long as the buffer, an offer, or the host
    /// pasteboard can read them, and the service reclaims the directory once none
    /// can — so the window must not delete the file it keeps, nor stage one
    /// anywhere else.
    ///
    /// Default `nil`: a text-only transport never takes a file drop.
    func reserveDropDestination() -> URL?

    /// Pulls the representations the clipboard window renders richly (text,
    /// inline RTF, images up to a size limit) for a lazily-offered guest payload,
    /// updating `clipboardContent` as they land.
    ///
    /// Default no-op: transports that deliver content eagerly have nothing to pull.
    func materializeForPreview() async

    /// Prepares the items to write to the host pasteboard for "Copy to Mac" —
    /// metadata only, synchronously.
    ///
    /// Every usable representation of a live guest offer becomes a `.promised`
    /// item whose bytes are pulled when a paste consumes them; with no live
    /// offer (local or user-edited content) the buffer's representations return
    /// `.resolved`. Reps that can never be served are reported as `.droppedFile`.
    func materializeForCopy() -> [CopyToMacItem]
}

/// A representation promised on the host pasteboard by its offer coordinates,
/// carrying the metadata the publisher needs to plan its pasteboard item and
/// route each flavor's paste-time pull.
struct CopyToMacPromise: Sendable, Equatable {
    let generation: UInt64
    let repIndex: Int
    let uti: String
    let filename: String
    /// Whether the rep inlines onto the pasteboard (the offer's `is_inline`),
    /// mirroring `shouldInlineOnPasteboard` for a resolved rep.
    let isInline: Bool
    /// Whether the publisher must leave `public.file-url` off the item it plans
    /// for this rep — the over-cap refusal for an image file, whose inline
    /// flavor keeps serving.
    let withholdsFileURL: Bool

    init(
        generation: UInt64, repIndex: Int, uti: String, filename: String, isInline: Bool,
        withholdsFileURL: Bool = false
    ) {
        self.generation = generation
        self.repIndex = repIndex
        self.uti = uti
        self.filename = filename
        self.isInline = isInline
        self.withholdsFileURL = withholdsFileURL
    }
}

/// One item "Copy to Mac" places on the host pasteboard.
enum CopyToMacItem: Sendable {
    /// A representation whose bytes are already local — the buffer's own content
    /// when no guest promise is live.
    case resolved(ClipboardContent.Representation)
    /// A rep promised by its offer coordinates; its bytes cross the wire only
    /// when a paste consumes them.
    case promised(CopyToMacPromise)
    /// A file payload that can't be served — the `reason` drives the
    /// user-facing message.
    case droppedFile(CopyToMacDropReason)
}

/// Why a "Copy to Mac" file payload couldn't be placed on the host pasteboard.
enum CopyToMacDropReason: Sendable, Equatable {
    /// The offer's `public.file-url`-serving reps total over the user's paste
    /// ceiling (`ClipboardPasteLimit`), so no paste could pull them inside the OS
    /// pasteboard-promise deadline. All-or-nothing: the whole set is refused
    /// together rather than landing piecemeal.
    case overPasteBudget
}

extension ClipboardServicing {
    func reserveDropDestination() -> URL? { nil }
    func materializeForPreview() async {}
    func reportIssue(_ issue: ClipboardTransferIssue) {}
    func materializeForCopy() -> [CopyToMacItem] {
        clipboardContent.representations.map { .resolved($0) }
    }

    /// Transports without byte-level progress never show a transfer bar.
    var transferProgress: ClipboardProgressSnapshot? { nil }

    /// Transports that never receive report no inbound offers.
    var inboundOfferSeq: UInt64 { 0 }
}
