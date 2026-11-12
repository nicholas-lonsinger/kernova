import Foundation
import KernovaKit
import KernovaTransferProgress
import KernovaWire

/// Common surface shared by every clipboard transport.
///
/// `SpiceClipboardService` carries only UTF-8 text; `HubClipboardService`, over the guest agent's items, carries
/// every representation. Both implementations must be `@Observable` classes: the macro installs the registrar
/// on the concrete type, so reading through the protocol witness still fires observation.
@MainActor
package protocol ClipboardServicing: AnyObject {
    /// `true` once the implementation has completed its handshake with the guest.
    var isConnected: Bool { get }

    /// `true` when the transport carries arbitrary UTI-tagged representations;
    /// `false` when it is limited to plain text (SPICE).
    var supportsBinaryRepresentations: Bool { get }

    /// Bumped once per new guest clipboard the transport takes, which passthrough writes to the Mac.
    var inboundOfferSeq: UInt64 { get }

    /// Stops protocol I/O. Idempotent.
    func stop()

    /// Passthrough stopped: what passthrough carried across ends, and each side's write of the other's is
    /// retracted. Default: nothing to end.
    func passthroughStopped()

    /// Offers a copy on the Mac to the guest, as passthrough read it from the host pasteboard: metadata only,
    /// each representation's bytes read from `copy` when this transport sends them.
    ///
    /// `.settled` means this copy is done with — announced, already held by the guest, or carrying nothing this
    /// transport can send. `.undelivered` means nothing reached the guest and offering the same copy again on a
    /// live connection would send it.
    func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome

    /// The Mac's pasteboard changed to a copy passthrough offers nothing of — empty, transient, or none of it
    /// readable: the host's offer of the copy before it is withdrawn. Default: nothing to withdraw.
    func hostCopyOffersNothing()

    /// Bumped once per connection to the guest, so passthrough tells a new connection from the last however
    /// fast one replaced the other. Default 0: a transport whose service is per connection.
    var connectionEpoch: UInt64 { get }

    /// The host pasteboard's change count when the connection now up started, so passthrough sends the guest
    /// only a Mac copy made since; nil when the transport keeps no record, and passthrough starts the
    /// connection where the pasteboard stands when it first sees it. Default nil.
    var connectionStartChangeCount: Int? { get }

    /// Copies `snapshot`, the Mac's clipboard as it stood at the command, to the guest's: what does not reach it
    /// at once, or nil. A refusal the guest answers later goes to the VM's transfer report.
    func copyMacClipboardToGuest(_ snapshot: ClipboardOfferSource) -> ClipboardTransferFailure?

    /// Copies the guest's clipboard as it stands now: once every representation but a file or folder landed
    /// here, `write` is handed it, synchronously, unless a newer copy of the guest's arrived first.
    func guestClipboardCopy(_ write: @escaping @MainActor (GuestCopyContents) -> Void) async -> GuestClipboardCopy

    /// Where a snapshot of the Mac's clipboard calls its file promises in, each snapshot holding the lease of
    /// its own; nil when the transport carries no file. Default nil.
    var snapshotStaging: ClipboardFileStaging? { get }

    /// The connection a copy of the Mac's clipboard goes over now, so a snapshot names by reference only what
    /// the guest at its end can fill; nil for a transport that fills no reference. Default nil.
    var clipboardConnection: ClipboardConnectionID? { get }

    /// Reserves a directory to call a file promise copied on the Mac in to when the guest pulls it, or `nil`
    /// when the transport can't stage one. Default `nil`: a text-only transport never takes a file.
    func reservePromiseDestination() -> URL?

    /// The guest's clipboard as passthrough places it on the host pasteboard — metadata only, synchronously.
    ///
    /// A live guest offer becomes one `.offer` whose bytes are pulled when a paste consumes them; text the
    /// transport already holds returns `.resolved`. Files that can never be served are reported as
    /// `.droppedFile`.
    func guestClipboardItems() -> [CopyToMacItem]
}

/// What became of a copy command's copy of the guest's clipboard.
package enum GuestClipboardCopy {
    /// It held nothing to copy.
    case nothing
    /// Its copy named only what the Mac's clipboard holds already: nothing was written.
    case alreadyHeld
    /// It could not be copied, and why.
    case failed(ClipboardTransferFailure)
    /// The copy landed and was handed to the write.
    case landed
}

/// A copy of the guest's clipboard: its items, every non-file representation landed, and the files still on
/// the guest's disk, pulled when pasted.
package struct GuestCopyContents {
    /// The copy, which a retraction of its write names by its token.
    let serving: ClipboardWriteSource.Serving
    let items: [OfferedItem]
    let concealed: Bool
    /// How the copy is written within the paste ceiling, decided once its INLINE representations landed.
    let plan: ClipboardPromisePolicy.CopyPlan
    /// What this side holds of representation `rep` of item `item`: an INLINE one's landed bytes, or a file a
    /// reference to this side's own offer was filled with.
    let held: @Sendable (_ item: Int, _ rep: Int) -> ClipboardWriteSource.Held?
    /// Pulls the copy's files when a paste asks.
    let puller: any ClipboardItemPulling
    /// How many of its references to this side's own offers could not be filled, and are left out.
    let referencesLeftOut: Int
    /// How many items of the guest's clipboard its snapshot does not carry whole.
    var itemsLeftOut = 0
    /// Lets the copy go, the Mac's clipboard holding nothing more of it.
    let release: @MainActor () -> Void
}

/// What became of an `offerHostCopy(_:)`.
///
/// Splits the one outcome a caller can act on — nothing reached the guest, and the same copy offered again on
/// a live connection would go out — from every outcome that is final for this copy.
package enum ClipboardGrabOutcome: Equatable, Sendable {
    case settled
    case undelivered
}

/// A guest's live offer as passthrough places it on the host pasteboard: every item promised, its bytes pulled
/// through `puller` only when a paste asks for them.
package struct CopyToMacOffer: Sendable {
    /// The offer, which a retraction of its write names by its token.
    let serving: ClipboardWriteSource.Serving
    let items: [OfferedItem]
    let concealed: Bool
    /// `false` leaves `public.file-url` off every item — the over-cap refusal,
    /// whose inline flavors keep serving.
    let servingFileURLs: Bool
    let puller: any ClipboardItemPulling
}

/// One item passthrough places on the host pasteboard.
package enum CopyToMacItem: Sendable {
    /// A representation whose bytes are already local — the text a text-only transport received.
    case resolved(ClipboardContent.Representation)
    /// A guest offer, promised whole; its bytes cross the wire only when a
    /// paste consumes them.
    case offer(CopyToMacOffer)
    /// A file payload that can't be served — the `reason` drives the
    /// user-facing message.
    case droppedFile(CopyToMacDropReason)
}

/// Why a file payload couldn't be placed on the host pasteboard.
package enum CopyToMacDropReason: Sendable, Equatable {
    /// The offer's `public.file-url`-serving reps total over the user's paste
    /// ceiling (`ClipboardPasteLimit`), so no paste could pull them inside the OS
    /// pasteboard-promise deadline. All-or-nothing: the whole set is refused
    /// together rather than landing piecemeal.
    case overPasteBudget
}

extension ClipboardServicing {
    func reservePromiseDestination() -> URL? { nil }
    var snapshotStaging: ClipboardFileStaging? { nil }
    var clipboardConnection: ClipboardConnectionID? { nil }
    func hostCopyOffersNothing() {}
    var connectionEpoch: UInt64 { 0 }
    var connectionStartChangeCount: Int? { nil }
    func passthroughStopped() {}
}
